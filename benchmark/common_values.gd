class_name CommonValues
extends Control

signal test_completed()
signal execution_finished();

@export var results_label: Label
@export var original_copy: BenchmarkControl
@export var new_copy: BenchmarkControl
@export var shader_dropdown: OptionButton
@export var image_size: SpinBox
@export var first_glow_pass: CheckBox
@export var timestamp_profile: CheckBox

static var singleton: CommonValues
static var IMAGE_SIZE: int = 1024
static var FIRST_GLOW_PASS: bool = true
static var PROFILE_TIMESTAMPS: bool = false

const TEST_COUNT: int = 6
const TEST_DELAY: float = 0.1;

static var times: Dictionary[String, float] = {}
static var result_images: Dictionary[String, Image] = {}
static var key: String = ""

var noise_channels: Array[FastNoiseLite] = []
var image: Image

var final_speeds: Dictionary[String, float] = {"new": 0., "original": 0.}
var final_errors: Dictionary[String, float] = {"max": 0., "mean": 0.}

func _ready() -> void:
    for i in range(4):
        noise_channels.append(FastNoiseLite.new())
    singleton = self
    initialize_data.call_deferred()

func initialize_data() -> void:
    IMAGE_SIZE = roundi(image_size.value)
    FIRST_GLOW_PASS = first_glow_pass.button_pressed
    PROFILE_TIMESTAMPS = timestamp_profile.button_pressed
    prepare_image()
    var index: int = shader_dropdown.get_selected_id()
    original_copy._initialize_pipeline(image, shader_dropdown.get_item_text(index))
    new_copy._initialize_pipeline(image, shader_dropdown.get_item_text(index))


# Generate gaussian noise of the specified size
func prepare_image() -> Image:
    var channel_colors: Array[Image]
    image = Image.create(IMAGE_SIZE, IMAGE_SIZE, false, Image.FORMAT_RGBA8) # Use a suitable format
    
    for noise in noise_channels:
        noise.seed = randi()
        # Create image from noise.
        channel_colors.append(noise.get_image(IMAGE_SIZE, IMAGE_SIZE, false, false))

    for x in range(IMAGE_SIZE):
        for y in range(IMAGE_SIZE):
            var color_floats: Array[float] = [0, 0, 0, 1]
            for channel in range(3):
                color_floats[channel] = channel_colors[channel].get_pixel(x, y).r
            image.set_pixel(x, y, Color(color_floats[0], color_floats[1], color_floats[2], 1.))

    return image


# Zero the test variables, then begin execution with basecase = total iteration count
func _on_execute_benchmark() -> void:
    final_speeds = {"new": 0., "original": 0.}
    final_errors = {"max": 0., "mean": 0.}
    _run_execution(TEST_COUNT)


# Callback executed when either shader completes
static func _post_execute(time: float, result_image: Image) -> void:
    times[key] = time
    result_images[key] = result_image.duplicate()
    singleton.execution_finished.emit()


func _run_execution(iter: int) -> void:
    # Randomly select which shader to try first
    if iter % 2 == 0:
        key = "original"
        original_copy.execute_benchmark(true)
        key = "new"
        new_copy.execute_benchmark(true)
    else:
        key = "new"
        new_copy.execute_benchmark(true)
        key = "original"
        original_copy.execute_benchmark(true)

    # Images were set during _post_execute callback
    var result_size: Vector2i = result_images["original"].get_size();
    
    var color_diff: Color = Color(0, 0, 0, 0)

    # Accumulate speed measurements values
    for keyi in final_speeds:
        final_speeds[keyi] += times[keyi]

    # Compute pixelwise errors
    var color_diff_max: float = 0.;
    for x in range(result_size.x):
        for y in range(result_size.y):
            var color_d: Color = result_images["original"].get_pixel(x, y) - result_images["new"].get_pixel(x, y)
            color_d = Color(absf(color_d.r), absf(color_d.g), absf(color_d.b), 0.)
            color_diff_max = maxf(color_diff_max, maxf(color_d.r, maxf(color_d.g, color_d.b)))
            color_diff += color_d

    # Normalize by the image size
    color_diff /= (result_size.x * result_size.y);

    # Accumulate computed errors into running statistic
    final_errors["max"] = maxf(color_diff_max, final_errors["max"])
    final_errors["mean"] += color_diff.r + color_diff.g + color_diff.b

    # Let the GPU breathe for a moment
    await get_tree().create_timer(TEST_DELAY).timeout

    # Repeat test if more iterations remain
    if iter > 0:
        _run_execution.call_deferred(iter - 1)
    # Else continue to the final report
    else:
        _process_errors()

# Report the final values accumulated
func _process_errors() -> void:
    final_errors["mean"] /= TEST_COUNT
    
    var old_timing: float = final_speeds["original"] / TEST_COUNT
    var new_timing: float = final_speeds["new"] / TEST_COUNT

    var average_speedup: float = final_speeds["original"] / final_speeds["new"]
    var max_abs_error: float = final_errors["max"]
    var avg_abs_error: float = final_errors["mean"]

    results_label.text = "Old: %f us" % [old_timing]
    results_label.text += "\nNew: %f us\n" % [new_timing]
    results_label.text += "\nAvg. Speedup: %4.2f" % [average_speedup]
    results_label.text += "\nMax. Error: %5.2f %%" % [max_abs_error * 100.0]
    results_label.text += "\nAvg. Error: %5.2f %%" % [avg_abs_error * 100.0]

    test_completed.emit.call_deferred();
