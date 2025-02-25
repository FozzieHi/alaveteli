require 'spec_helper'

RSpec.describe AttachmentsController, type: :controller do

  before do
    allow(@controller).to receive(:foi_fragment_cache_write)
  end

  describe 'GET show' do

    let(:info_request) do
      FactoryBot.create(
        :info_request_with_incoming_attachments, public_token: 'ABC'
      )
    end

    let(:default_params) do
      { incoming_message_id: info_request.incoming_messages.first.id,
        id: info_request.id,
        part: 2,
        file_name: 'interesting.pdf' }
    end

    def show(params = {})
      get :show, params: default_params.merge(params)
    end

    it 'should be able to find the request using public token' do
      expect(InfoRequest).to receive(:find_by!).with(public_token: 'ABC').
        and_return(info_request)

      show(public_token: 'ABC', id: nil)

      expect(assigns(:info_request)).to eq(info_request)
    end

    it 'adds noindex header when using public token' do
      expect(InfoRequest).to receive(:find_by!).with(public_token: 'ABC').
        and_return(info_request)

      show(public_token: 'ABC', id: nil)

      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it 'should cache an attachment on a request with normal prominence' do
      expect(@controller).to receive(:foi_fragment_cache_write)
      show
    end

    it 'sets the correct read permissions for the new file' do
      # allow file to be written to disk
      allow(@controller).to receive(:foi_fragment_cache_write).and_call_original

      # write file to disk
      show

      # check the file permissions
      key_path = @controller.send(:cache_key_path)
      octal_stat = format("%o", File.stat(key_path).mode)[-4..-1]
      expect(octal_stat).to eq('0644')

      # clean up and remove the file
      File.delete(key_path)
    end

    # This is a regression test for a bug where URLs of this form were causing 500 errors
    # instead of 404s.
    #
    # (Note that in fact only the integer-prefix of the URL part is used, so there are
    # *some* “ugly URLs containing a request id that isn't an integer” that actually return
    # a 200 response. The point is that IDs of this sort were triggering an error in the
    # error-handling path, causing the wrong sort of error response to be returned in the
    # case where the integer prefix referred to the wrong request.)
    #
    # https://github.com/mysociety/alaveteli/issues/351
    it "should return 404 for ugly URLs containing a request id that isn't an integer" do
      ugly_id = "55195"
      expect { show(id: ugly_id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "should return 404 when incoming message and request ids
        don't match" do
      expect { show(id: info_request.id + 1) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "should return 404 for ugly URLs contain a request id that isn't an
        integer, even if the integer prefix refers to an actual request" do
      ugly_id = "#{FactoryBot.create(:info_request).id}95"
      expect { show(id: ugly_id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "should redirect to the incoming message if there's a wrong part number
        and an ambiguous filename" do
      incoming_message = info_request.incoming_messages.first
      attachment = IncomingMessage.
        get_attachment_by_url_part_number_and_filename!(
          incoming_message.get_attachments_for_display,
          5,
          'interesting.pdf'
        )
      expect(attachment).to be_nil
      show(part: 5)
      expect(response.status).to eq(303)
      new_location = response.header['Location']
      expect(new_location)
        .to match incoming_message_path(incoming_message)
    end

    it "should find a uniquely named filename even if the URL part number was wrong" do
      info_request = FactoryBot.create(:info_request_with_html_attachment)
      get :show,
           params: {
             incoming_message_id: info_request.incoming_messages.first.id,
             id: info_request.id,
             part: 5,
             file_name: 'interesting.html',
             skip_cache: 1
           }
      expect(response.body).to match('dull')
    end

    it "should not download attachments with wrong file name" do
      info_request = FactoryBot.create(:info_request_with_html_attachment)
      get :show,
           params: {
             incoming_message_id: info_request.incoming_messages.first.id,
             id: info_request.id,
             part: 2,
             file_name: 'http://trying.to.hack',
             skip_cache: 1
           }
      expect(response.status).to eq(303)
    end

    it "should sanitise HTML attachments" do
      info_request = FactoryBot.create(:info_request_with_html_attachment)
      get :show,
          params: {
            incoming_message_id: info_request.incoming_messages.first.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.html',
            skip_cache: 1
          }

      # Nokogiri adds the meta tag; see
      # https://github.com/sparklemotion/nokogiri/issues/1008
      expected = <<-EOF.squish
      <!DOCTYPE html>
      <html>
        <head>
          <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        </head>
        <body>dull
        </body>
      </html>
      EOF

      expect(response.body.squish).to eq(expected)
    end

    it "censors attachments downloaded directly" do
      info_request = FactoryBot.create(:info_request_with_html_attachment)
      info_request.censor_rules.create!(text: 'dull',
                                       replacement: "Mouse",
                                       last_edit_editor: 'unknown',
                                       last_edit_comment: 'none')
      get :show,
          params: {
            incoming_message_id: info_request.incoming_messages.first.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.html',
            skip_cache: 1
          }
      expect(response.media_type).to eq('text/html')
      expect(response.body).to have_content "Mouse"
    end

    it "should censor with rules on the user (rather than the request)" do
      info_request = FactoryBot.create(:info_request_with_html_attachment)
      info_request.user.censor_rules.create!(text: 'dull',
                                       replacement: "Mouse",
                                       last_edit_editor: 'unknown',
                                       last_edit_comment: 'none')
      get :show,
          params: {
            incoming_message_id: info_request.incoming_messages.first.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.html',
            skip_cache: 1
          }
      expect(response.media_type).to eq('text/html')
      expect(response.body).to have_content "Mouse"
    end

    it 'returns an ActiveRecord::RecordNotFound error for an embargoed request' do
      info_request = FactoryBot.create(:embargoed_request)
      expect {
        get :show,
            params: {
              incoming_message_id: info_request.incoming_messages.first.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf',
              skip_cache: 1
            }
      }.to raise_error ActiveRecord::RecordNotFound
    end

    context 'with project_id params and logged in project member' do
      let(:user) { project.owner }
      let(:project) { FactoryBot.create(:project) }

      before do
        sign_in user
        allow(controller).to receive(:current_user).and_return(user)
      end

      it 'assigns project' do
        show(project_id: project.id)
        expect(assigns(:project)).to eq project
      end

      it 'passes project to current ability' do
        expect(Ability).to receive(:new).with(
          user, project: project, public_token: false
        ).and_call_original
        show(project_id: project.id)
      end
    end

    context 'with project_id params and logged in non project member' do
      let(:user) { FactoryBot.create(:user) }
      let(:project) { FactoryBot.create(:project) }

      before do
        sign_in user
        allow(controller).to receive(:current_user).and_return(user)
      end

      it 'does not assigns project' do
        show(project_id: project.id)
        expect(assigns(:project)).to eq nil
      end

      it 'does not pass project to current ability' do
        expect(Ability).to receive(:new).with(
          user, project: nil, public_token: false
        ).and_call_original
        show(project_id: project.id)
      end
    end

    context 'with public_token params and logged out' do
      it 'passes project to current ability' do
        expect(Ability).to receive(:new).with(
          nil, project: nil, public_token: true
        ).and_call_original
        show(public_token: 'ABC')
      end
    end
  end

  describe 'GET show_as_html' do
    let(:info_request) { FactoryBot.create(:info_request_with_incoming_attachments) }

    def get_html_attachment(params = {})
      default_params = { incoming_message_id:                            info_request.incoming_messages.first.id,
                         id: info_request.id,
                         part: 2,
                         file_name: 'interesting.pdf.html' }
      get :show_as_html, params: default_params.merge(params)
    end

    it 'should be able to find the request using public token' do
      expect(InfoRequest).to receive(:find_by!).with(public_token: '123').
        and_return(info_request)

      get_html_attachment(public_token: '123', id: nil)

      expect(assigns(:info_request)).to eq(info_request)
    end

    it 'adds noindex header when using public token' do
      expect(InfoRequest).to receive(:find_by!).with(public_token: '123').
        and_return(info_request)

      get_html_attachment(public_token: '123', id: nil)

      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it "should return 404 for ugly URLs containing a request id that isn't an integer" do
      ugly_id = "55195"
      expect { get_html_attachment(id: ugly_id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "should return 404 for ugly URLs contain a request id that isn't an
        integer, even if the integer prefix refers to an actual request" do
      ugly_id = "#{FactoryBot.create(:info_request).id}95"
      expect { get_html_attachment(id: ugly_id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'returns an ActiveRecord::RecordNotFound error for an embargoed request' do
      info_request = FactoryBot.create(:embargoed_request)
      expect {
        get :show_as_html,
            params: {
              incoming_message_id: info_request.incoming_messages.first.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf.html'
            }
      }.to raise_error ActiveRecord::RecordNotFound
    end

  end

end

RSpec.describe AttachmentsController, 'when handling prominence',
    type: :controller do

  def expect_hidden(hidden_template)
    expect(response.media_type).to eq('text/html')
    expect(response).to render_template(hidden_template)
    expect(response.code).to eq('403')
  end

  let(:info_request) do
    FactoryBot.
      create(:info_request_with_incoming_attachments, prominence: prominence)
  end

  let(:incoming_message) do
    FactoryBot.create(:incoming_message_with_attachments,
                      prominence: prominence)
  end

  let(:attachment) do
    FactoryBot.create(:pdf_attachment,
                      prominence: prominence,
                      incoming_message: FactoryBot.build(:incoming_message))
  end

  context 'when the request is hidden' do
    let(:prominence) { 'hidden' }
    let(:incoming_message) { info_request.incoming_messages.first }

    it 'does not download attachments' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden')
    end

    it 'does not generate an HTML version of an attachment for a request whose prominence is hidden even for an admin but should return a 404' do
      sign_in FactoryBot.create(:admin_user)
      expect do
        get :show_as_html,
            params: {
              incoming_message_id: incoming_message.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf'
            }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

  end

  context 'when the request is requester_only' do
    let(:prominence) { 'requester_only' }
    let(:incoming_message) { info_request.incoming_messages.first }

    it 'does not cache an attachment when showing an attachment to the requester' do
      sign_in info_request.user
      expect(@controller).not_to receive(:foi_fragment_cache_write)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
    end

    it 'does not cache an attachment when showing an attachment to the admin' do
      sign_in FactoryBot.create(:admin_user)
      expect(@controller).not_to receive(:foi_fragment_cache_write)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
    end
  end

  context 'when the request is backpage' do
    let(:prominence) { 'backpage' }
    let(:incoming_message) { info_request.incoming_messages.first }

    it 'sets a noindex header when viewing' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it 'sets a noindex header when viewing a cached copy' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it 'sets a noindex header when viewing a HTML version' do
      get :show_as_html,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it 'sets a noindex header when viewing a cached HTML version' do
      get :show_as_html,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
      expect(response.headers['X-Robots-Tag']).to eq 'noindex'
    end

    it 'does not cache an attachment' do
      sign_in info_request.user
      expect(@controller).not_to receive(:foi_fragment_cache_write)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
    end
  end

  context 'when the incoming message has prominence hidden' do
    let(:prominence) { 'hidden' }
    let(:info_request) { incoming_message.info_request }

    it 'does not download attachments for a non-logged in user' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_correspondence')
    end

    it 'does not download attachments for the request owner' do
      sign_in info_request.user
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_correspondence')
    end

    it 'downloads attachments for an admin user' do
      sign_in FactoryBot.create(:admin_user)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'should not generate an HTML version of an attachment for a request whose prominence is hidden even for an admin but should return a 404' do
      sign_in FactoryBot.create(:admin_user)
      expect do
        get :show_as_html,
            params: {
              incoming_message_id: incoming_message.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf',
              skip_cache: 1
            }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'does not cache an attachment when showing an attachment to the requester or admin' do
      sign_in info_request.user
      expect(@controller).not_to receive(:foi_fragment_cache_write)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
    end
  end

  context 'when the incoming message has prominence requester_only' do
    let(:prominence) { 'requester_only' }
    let(:info_request) { incoming_message.info_request }

    it 'does not download attachments for a non-logged in user' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_correspondence')
    end

    it 'downloads attachments for the request owner' do
      sign_in info_request.user
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'downloads attachments for an admin user' do
      sign_in FactoryBot.create(:admin_user)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'should not generate an HTML version of an attachment for a request whose prominence is hidden even for an admin but should return a 404' do
      sign_in FactoryBot.create(:admin_user)
      expect do
        get :show_as_html,
            params: {
              incoming_message_id: incoming_message.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf',
              skip_cache: 1
            }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'when the attachment has prominence hidden' do
    let(:prominence) { 'hidden' }
    let(:info_request) { incoming_message.info_request }
    let(:incoming_message) { attachment.incoming_message }

    it 'does not download attachments for a non-logged in user' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_attachment')
    end

    it 'does not download attachments for the request owner' do
      sign_in info_request.user
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_attachment')
    end

    it 'downloads attachments for an admin user' do
      sign_in FactoryBot.create(:admin_user)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'should not generate an HTML version of an attachment whose prominence is hidden even for an admin but should return a 404' do
      sign_in FactoryBot.create(:admin_user)
      expect do
        get :show_as_html,
            params: {
              incoming_message_id: incoming_message.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf',
              skip_cache: 1
            }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'does not cache an attachment when showing an attachment to the requester or admin' do
      sign_in info_request.user
      expect(@controller).not_to receive(:foi_fragment_cache_write)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf'
          }
    end
  end

  context 'when the attachment has prominence requester_only' do
    let(:prominence) { 'requester_only' }
    let(:info_request) { incoming_message.info_request }
    let(:incoming_message) { attachment.incoming_message }

    it 'does not download attachments for a non-logged in user' do
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect_hidden('request/hidden_attachment')
    end

    it 'downloads attachments for the request owner' do
      sign_in info_request.user
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'downloads attachments for an admin user' do
      sign_in FactoryBot.create(:admin_user)
      get :show,
          params: {
            incoming_message_id: incoming_message.id,
            id: info_request.id,
            part: 2,
            file_name: 'interesting.pdf',
            skip_cache: 1
          }
      expect(response.media_type).to eq('application/pdf')
      expect(response).to be_successful
    end

    it 'should not generate an HTML version of an attachment whose prominence is hidden even for an admin but should return a 404' do
      sign_in FactoryBot.create(:admin_user)
      expect do
        get :show_as_html,
            params: {
              incoming_message_id: incoming_message.id,
              id: info_request.id,
              part: 2,
              file_name: 'interesting.pdf',
              skip_cache: 1
            }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end

RSpec.describe AttachmentsController, "when caching fragments",
    type: :controller do

  let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
  let(:incoming_message) { info_request.incoming_messages.first }

  it "should not fail with long filenames" do
    long_name = 'blah' * 150 + '.pdf'

    attachment = FactoryBot.create(:pdf_attachment,
                                   filename: long_name,
                                   incoming_message: incoming_message,
                                   url_part_number: 2)

    params = { file_name: long_name,
               controller: 'request',
               action: 'show_as_html',
               id: info_request.id,
               incoming_message_id: incoming_message.id,
               part: '2' }

    get :show_as_html, params: params

    expect(response).to be_successful
  end

end
