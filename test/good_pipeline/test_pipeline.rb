# frozen_string_literal: true

require "test_helper"

class TestPipeline < Minitest::Test
  DownloadJob = Class.new
  TranscodeJob = Class.new
  ThumbnailJob = Class.new
  PublishJob = Class.new
  CleanupJob = Class.new

  # --- Defaults ---

  def test_default_failure_strategy_is_halt
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :halt, klass.failure_strategy
  end

  def test_default_description_is_nil
    klass = Class.new(GoodPipeline::Pipeline)
    assert_nil klass.description
  end

  def test_default_callbacks_are_nil
    klass = Class.new(GoodPipeline::Pipeline)
    assert_nil klass.on_complete
    assert_nil klass.on_success
    assert_nil klass.on_failure
  end

  # --- Class DSL: description ---

  def test_description_setter_and_getter
    klass = Class.new(GoodPipeline::Pipeline) do
      description "Process videos"
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal "Process videos", klass.description
  end

  # --- Class DSL: failure_strategy ---

  def test_failure_strategy_halt
    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :halt, klass.failure_strategy
  end

  def test_failure_strategy_continue
    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :continue
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :continue, klass.failure_strategy
  end

  def test_failure_strategy_ignore
    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :ignore
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :ignore, klass.failure_strategy
  end

  def test_invalid_failure_strategy_raises
    error = assert_raises(GoodPipeline::ConfigurationError) do
      Class.new(GoodPipeline::Pipeline) do
        failure_strategy :explode
      end
    end
    assert_includes error.message, "invalid failure strategy :explode"
    assert_includes error.message, ":halt"
    assert_includes error.message, ":continue"
    assert_includes error.message, ":ignore"
  end

  # --- Class DSL: callbacks ---

  def test_on_complete_callback
    klass = Class.new(GoodPipeline::Pipeline) do
      on_complete :notify_complete
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :notify_complete, klass.on_complete
  end

  def test_on_success_callback
    klass = Class.new(GoodPipeline::Pipeline) do
      on_success :notify_success
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :notify_success, klass.on_success
  end

  def test_on_failure_callback
    klass = Class.new(GoodPipeline::Pipeline) do
      on_failure :notify_failure
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :notify_failure, klass.on_failure
  end

  # --- Inheritance ---

  def test_subclass_inherits_parent_settings
    parent = Class.new(GoodPipeline::Pipeline) do
      description "Parent pipeline"
      failure_strategy :continue
      on_complete :done
      on_success :yay
      on_failure :oops
    end

    child = Class.new(parent) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end

    assert_equal "Parent pipeline", child.description
    assert_equal :continue, child.failure_strategy
    assert_equal :done, child.on_complete
    assert_equal :yay, child.on_success
    assert_equal :oops, child.on_failure
  end

  def test_subclass_override_does_not_affect_parent
    parent = Class.new(GoodPipeline::Pipeline) do
      description "Parent"
      failure_strategy :halt
    end

    Class.new(parent) do
      description "Child"
      failure_strategy :continue
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end

    assert_equal "Parent", parent.description
    assert_equal :halt, parent.failure_strategy
  end

  # --- Instance lifecycle ---

  def test_class_run_returns_instance
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run
    assert_instance_of klass, instance
  end

  def test_params_stored_and_frozen
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run(video_id: 42)
    assert_equal({ video_id: 42 }, instance.params)
    assert instance.params.frozen?
  end

  def test_instance_is_frozen
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run
    assert instance.frozen?
  end

  def test_step_definitions_frozen
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run
    assert instance.step_definitions.frozen?
  end

  # --- DSL verb: run inside configure ---

  def test_run_creates_step_definitions
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :download, TestPipeline::DownloadJob
        run :transcode, TestPipeline::TranscodeJob, after: :download
      end
    end

    instance = klass.run
    assert_equal 2, instance.step_definitions.size
    assert_equal :download, instance.step_definitions[0].key
    assert_equal :transcode, instance.step_definitions[1].key
  end

  def test_run_passes_all_options
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :transcode, TestPipeline::TranscodeJob
        run :download, TestPipeline::DownloadJob,
            with: { url: "https://example.com" },
            after: :transcode,
            on_failure: :retry,
            queue: "high",
            priority: 10
      end
    end

    instance = klass.run
    step = instance.step_definitions.find { |s| s.key == :download }
    assert_equal({ url: "https://example.com" }, step.params)
    assert_equal [:transcode], step.dependencies
    assert_equal :retry, step.on_failure
    assert_equal "high", step.queue
    assert_equal 10, step.priority
  end

  def test_run_defaults_with_to_empty_hash
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run
    assert_equal({}, instance.step_definitions[0].params)
  end

  def test_run_normalizes_after_to_array
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :a, TestPipeline::DownloadJob
        run :b, TestPipeline::TranscodeJob, after: :a
      end
    end
    instance = klass.run
    assert_equal [:a], instance.step_definitions[1].dependencies
  end

  # --- Validation integration ---

  def test_empty_configure_raises
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**); end
    end

    assert_raises(GoodPipeline::InvalidPipelineError) { klass.run }
  end

  def test_duplicate_keys_raise
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :a, TestPipeline::DownloadJob
        run :a, TestPipeline::TranscodeJob
      end
    end

    error = assert_raises(GoodPipeline::InvalidPipelineError) { klass.run }
    assert_equal "duplicate step key :a", error.message
  end

  def test_unknown_references_raise
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :a, TestPipeline::DownloadJob, after: :missing
      end
    end

    error = assert_raises(GoodPipeline::InvalidPipelineError) { klass.run }
    assert_includes error.message, "unknown dependency :missing"
  end

  def test_cycles_raise
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :a, TestPipeline::DownloadJob, after: :b
        run :b, TestPipeline::TranscodeJob, after: :a
      end
    end

    error = assert_raises(GoodPipeline::InvalidPipelineError) { klass.run }
    assert_includes error.message, "cycle detected:"
  end

  def test_valid_dag_passes
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :a, TestPipeline::DownloadJob
        run :b, TestPipeline::TranscodeJob, after: :a
        run :c, TestPipeline::ThumbnailJob, after: :a
        run :d, TestPipeline::PublishJob, after: %i[b c]
      end
    end

    klass.run # should not raise
  end

  # --- Topology: steps_by_key and root_steps ---

  def test_steps_by_key_returns_hash
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :download, TestPipeline::DownloadJob
        run :transcode, TestPipeline::TranscodeJob, after: :download
      end
    end

    instance = klass.run
    assert_instance_of Hash, instance.steps_by_key
    assert_equal %i[download transcode], instance.steps_by_key.keys
    assert_equal :download, instance.steps_by_key[:download].key
    assert instance.steps_by_key.frozen?
  end

  def test_root_steps_returns_dependency_free_steps
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**)
        run :download, TestPipeline::DownloadJob
        run :extract, TestPipeline::TranscodeJob
        run :transcode, TestPipeline::ThumbnailJob, after: :download
      end
    end

    instance = klass.run
    root_keys = instance.root_steps.map(&:key)
    assert_equal %i[download extract], root_keys
    assert instance.root_steps.frozen?
  end

  # --- Delegation ---

  def test_instance_delegates_description
    klass = Class.new(GoodPipeline::Pipeline) do
      description "My pipeline"
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal "My pipeline", klass.run.description
  end

  def test_instance_delegates_failure_strategy
    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :continue
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    assert_equal :continue, klass.run.failure_strategy
  end

  def test_instance_delegates_callbacks
    klass = Class.new(GoodPipeline::Pipeline) do
      on_complete :done
      on_success :yay
      on_failure :oops
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run
    assert_equal :done, instance.on_complete_callback
    assert_equal :yay, instance.on_success_callback
    assert_equal :oops, instance.on_failure_callback
  end

  # --- NotImplementedError ---

  def test_base_pipeline_without_configure_raises
    error = assert_raises(NotImplementedError) { GoodPipeline::Pipeline.run }
    assert_includes error.message, "must implement #configure"
  end

  # --- run outside configure raises ---

  def test_run_outside_configure_raises
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, TestPipeline::DownloadJob)
    end
    instance = klass.run

    assert_raises(GoodPipeline::ConfigurationError) do
      instance.send(:run, :b, TestPipeline::TranscodeJob)
    end
  end

  # --- Design doc example ---

  def test_video_processing_pipeline
    klass = Class.new(GoodPipeline::Pipeline) do
      description "Video processing pipeline"
      failure_strategy :halt
      on_complete :notify
      on_success :celebrate
      on_failure :alert

      def configure(video_id:, **)
        run :download, TestPipeline::DownloadJob, with: { video_id: video_id }
        run :transcode, TestPipeline::TranscodeJob, after: :download
        run :thumbnail, TestPipeline::ThumbnailJob, after: :download
        run :publish, TestPipeline::PublishJob, after: %i[transcode thumbnail]
        run :cleanup, TestPipeline::CleanupJob, after: :publish
      end
    end

    instance = klass.run(video_id: 123)

    assert_equal 5, instance.step_definitions.size
    assert_equal({ video_id: 123 }, instance.params)
    assert_equal "Video processing pipeline", instance.description
    assert_equal :halt, instance.failure_strategy
    assert_equal :notify, instance.on_complete_callback
    assert_equal :celebrate, instance.on_success_callback
    assert_equal :alert, instance.on_failure_callback

    assert_equal %i[download transcode thumbnail publish cleanup], instance.step_definitions.map(&:key)
    assert_equal [:download], instance.root_steps.map(&:key)
    assert_equal({ video_id: 123 }, instance.steps_by_key[:download].params)
    assert_equal %i[transcode thumbnail], instance.steps_by_key[:publish].dependencies
  end

  # --- Params forwarded to configure ---

  def test_params_forwarded_to_configure
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(video_id:, **)
        run :download, TestPipeline::DownloadJob, with: { id: video_id }
      end
    end

    instance = klass.run(video_id: 99)
    assert_equal({ id: 99 }, instance.step_definitions[0].params)
  end
end
