# coding: UTF-8

require "spec_helper"
require "dea/staging_task"
require "dea/directory_server_v2"
require "em-http"

describe Dea::StagingTask do
  let(:config) do
    {
      "base_dir" => ".",
      "directory_server" => {"file_api_port" => 1234},
      "staging" => {"environment" => {}},
    }
  end

  let(:bootstrap) { mock(:bootstrap, :config => config) }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }

  let(:logger) do
    mock("logger").tap do |l|
      %w(debug debug2 info warn).each { |m| l.stub(m) }
    end
  end

  let(:staging) { Dea::StagingTask.new(bootstrap, dir_server, valid_staging_attributes) }
  let(:workspace_dir) { Dir.mktmpdir("somewhere") }

  before do
    staging.stub(:workspace_dir) { workspace_dir }
    staging.stub(:staged_droplet_path) { __FILE__ }
    staging.stub(:downloaded_droplet_path) { "/path/to/downloaded/droplet" }
    staging.stub(:logger) { logger }
  end

  describe "#promise_stage" do
    let(:staging_env) { { "PATH" => "x", "FOO" => "y" } }
    it "assembles a shell command and initiates collection of task log" do
      staging.should_receive(:staging_environment).and_return(staging_env)

      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        staging_env.each do |k, v|
          cmd.should include("#{k}=#{v}")
        end

        cmd.should include("mkdir -p /tmp/staged/logs")
        cmd.should include("bin/run_plugin")
        cmd.should include("plugin_config")
        mock("promise", :resolve => nil)
      end

      staging.should_receive(:promise_task_log) { mock("promise", :resolve => nil) }

      staging.promise_stage.resolve
    end

    it "initiates collection of task log if script fails to run" do
      staging.should_receive(:staging_environment).and_return(staging_env)

      staging.should_receive(:promise_warden_run) { raise RuntimeError.new("Script Failed") }

      staging.should_receive(:promise_task_log) { mock("promise", :resolve => nil) }

      expect { staging.promise_stage.resolve }.to raise_error "Script Failed"
    end
  end

  describe "#task_id" do
    it "generates a guid" do
      VCAP.should_receive(:secure_uuid).and_return("the_uuid")
      staging.task_id.should == "the_uuid"
    end

    it "persists" do
      VCAP.should_receive(:secure_uuid).once.and_return("the_uuid")
      staging.task_id.should == "the_uuid"
      staging.task_id.should == "the_uuid"
    end
  end

  describe "#task_log" do
    subject { staging.task_log }

    describe "when staging has not yet started" do
      it { should be_nil }
    end

    describe "once staging has started" do
      before do
        File.open(File.join(workspace_dir, "staging_task.log"), "w") do |f|
          f.write "some log content"
        end
      end

      it "reads the staging log file" do
        staging.task_log.should == "some log content"
      end
    end
  end

  describe "#streaming_log_url" do
    let(:url) { staging.streaming_log_url }

    it "returns url for staging log" do
      url.should include("/tasks/#{staging.task_id}/file_path", )
    end

    it "includes path to staging task output" do
      url.should include "path=/tmp/staged/logs/staging_task.log"
    end

    it "hmacs url" do
      url.should match(/hmac=.*/)
    end
  end

  describe "#path_in_container" do
    context "when container path is set" do
      before { staging.stub(:container_path => "/container/path") }
      it "returns path inside warden container" do
        staging.path_in_container("path/to/file").should == "/container/path/path/to/file"
      end
    end

    context "when container path is not set" do
      before { staging.stub(:container_path => nil) }
      it "returns nil" do
        staging.path_in_container("path/to/file").should be_nil
      end
    end
  end

  describe "#start" do
    let(:successful_promise) { Dea::Promise.new {|p| p.deliver } }
    let(:failing_promise) { Dea::Promise.new {|p| raise "failing promise" } }

    def stub_staging_setup
      staging.stub(:prepare_workspace)
      staging.stub(:promise_app_download).and_return(successful_promise)
      staging.stub(:promise_create_container).and_return(successful_promise)
      staging.stub(:promise_container_info).and_return(successful_promise)
    end

    def stub_staging
      staging.stub(:promise_unpack_app).and_return(successful_promise)
      staging.stub(:promise_stage).and_return(successful_promise)
      staging.stub(:promise_pack_app).and_return(successful_promise)
      staging.stub(:promise_copy_out).and_return(successful_promise)
      staging.stub(:promise_app_upload).and_return(successful_promise)
      staging.stub(:promise_destroy).and_return(successful_promise)
    end

    it "should clean up after itself" do
      staging.stub(:prepare_workspace).and_raise("Error")
      expect { staging.start }.to raise_error(/Error/)
      File.exists?(workspace_dir).should be_false
    end

    it "prepare workspace, download app source, creates container and then obtains container info" do
      %w(prepare_workspace promise_app_download promise_create_container promise_container_info).each do |step|
        staging.should_receive(step).ordered.and_return(successful_promise)
      end

      stub_staging
      staging.start
    end

    it "unpacks, stages, repacks, copies files out of container, upload staged app and then destroys" do
      %w(unpack_app stage pack_app copy_out app_upload destroy).each do |step|
        staging.should_receive("promise_#{step}").ordered.and_return(successful_promise)
      end

      stub_staging_setup
      staging.start
    end

    describe "after_setup callback" do
      before do
        stub_staging_setup
        stub_staging
      end

      context "when there is no callback registered" do
        it "doesn't not try to call registered callback" do
          staging.start
        end
      end

      context "when there is callback registered" do
        before do
          @received_count = 0
          @received_error = nil
          staging.after_setup { |error| @received_count += 1; @received_error = error }
        end

        context "when staging task succeeds finishing setup" do
          it "calls registered callback without an error" do
            staging.start
            @received_count.should == 1
            @received_error.should be_nil
          end
        end

        context "when staging task fails before finishing setup" do
          before { staging.stub(:promise_app_download).and_return(failing_promise) }

          it "calls registered callback with an error" do
            staging.start rescue nil
            @received_count.should == 1
            @received_error.to_s.should == "failing promise"
          end
        end

        context "when the callback itself fails" do
          before do
            staging.after_setup { |_| @received_count += 1; raise "failing callback" }
          end

          it "calls registered callback exactly once" do
            staging.start rescue nil
            @received_count.should == 1
          end

          it "propagates raised error" do
            expect {
              staging.start
            }.to raise_error(/failing callback/)
          end
        end
      end
    end
  end

  describe "#finish_task" do
    context "when an error is passed" do
      let(:fake_error) { StandardError.new("fake error") }

      it "calls the callback with the error, then raises the error" do
        expect {
          staging.finish_task(fake_error) do |error|
            error.should == fake_error
          end
        }.to raise_error(fake_error)
      end
    end

    context "when no error is passed" do
      it "cleans up the workspace after calling the callback" do
        callback_called = false

        staging.finish_task(nil) do
          callback_called = true
          File.exists?(workspace_dir).should be_true
        end

        callback_called.should be_true
        File.exists?(workspace_dir).should be_false
      end
    end
  end

  describe "#promise_container_info" do
    def resolve_promise
      staging.promise_container_info.resolve
    end

    context "when container handle is set" do
      let(:warden_info_response) do
        Warden::Protocol::InfoResponse.new(:container_path => "/container/path")
      end

      before { staging.stub(:container_handle => "container-handle") }

      it "makes warden info request" do
        staging.should_receive(:promise_warden_call).and_return do |type, request|
          type.should == :info
          request.handle.should == "container-handle"
          mock(:promise, :resolve => warden_info_response)
        end

        resolve_promise
      end

      context "when container_path is provided" do
        it "sets container_path" do
          staging.stub(:promise_warden_call).and_return do
            mock(:promise, :resolve => warden_info_response)
          end

          expect {
            resolve_promise
          }.to change { staging.container_path }.from(nil).to("/container/path")
        end
      end

      context "when container_path is not provided" do
        it "raises error" do
          staging.stub(:promise_warden_call).and_return do
            response = Warden::Protocol::InfoResponse.new
            mock(:promise, :resolve => response)
          end

          expect {
            resolve_promise
          }.to raise_error(RuntimeError, /container path is not available/)
        end
      end
    end

    context "when container handle is not set" do
      before { staging.stub(:container_handle => nil) }

      it "raises error" do
        expect {
          resolve_promise
        }.to raise_error(ArgumentError, /container handle must not be nil/)
      end
    end
  end

  describe '#promise_app_download' do
    subject do
      promise = staging.promise_app_download
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before { Download.any_instance.stub(:download!).and_yield("This is an error", nil) }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context 'when there is no error' do
      before do
        File.stub(:rename)
        File.stub(:chmod)
        Download.any_instance.stub(:download!).and_yield(nil, "/path/to/file")
      end
      its(:result) { should == [:deliver, nil]}

      it "should rename the file" do
        File.should_receive(:rename).with("/path/to/file", "/path/to/downloaded/droplet")
        File.should_receive(:chmod).with(0744, "/path/to/downloaded/droplet")
        subject
      end
    end
  end

  describe "#promise_unpack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("unzip -q /path/to/downloaded/droplet -d /tmp/unstaged")
        mock("promise", :resolve => nil)
      end

      staging.promise_unpack_app.resolve
    end
  end

  describe "#promise_pack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("cd /tmp/staged && COPYFILE_DISABLE=true tar -czf /tmp/droplet.tgz .")
        mock("promise", :resolve => nil)
      end

      staging.promise_pack_app.resolve
    end
  end

  describe '#promise_app_upload' do
    subject do
      promise = staging.promise_app_upload
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before { Upload.any_instance.stub(:upload!).and_yield("This is an error") }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context 'when there is no error' do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil]}
    end
  end

  describe '#promise_copy_out' do
    subject do
      promise = staging.promise_copy_out
      promise.resolve
      promise
    end

    it 'should print out some info' do
      staging.stub(:copy_out_request)
      logger.should_receive(:info).with(anything)
      subject
    end

    it 'should send copying out request' do
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGED_DROPLET, /.{5,}/)
      subject
    end
  end

  describe "#promise_task_log" do
    subject do
      promise = staging.promise_task_log
      promise.resolve
      promise
    end

    it 'should send copying out request' do
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGING_LOG, /#{workspace_dir}/)
      subject
    end

    it "should write the staging log to the main logger" do
      logger.should_receive(:info).with(anything)
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGING_LOG, /#{workspace_dir}/)
      subject
    end
  end
end
