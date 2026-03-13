class_name BenchmarkControl
extends Control

@export_file("*.glsl") var shader_file: String
@export var initial_shader_version: String
@onready var image_rect: TextureRect = $TextureComparison/InputRect
@onready var output_rect: TextureRect = $TextureComparison/ResultRect

const SAMPLE_ITERATIONS: int = 20

var noise_channels: Array[FastNoiseLite] = []

var rd: RenderingDevice
var shader: RID

@warning_ignore("INTEGER_DIVISION")
var workgroups_x: int = int(CommonValues.IMAGE_SIZE / 2 / 8)
@warning_ignore("INTEGER_DIVISION")
var workgroups_y: int = int(CommonValues.IMAGE_SIZE / 2 / 8)

var sampler_state: RDSamplerState
var sampler_rid: RID
var image: Image
var image_format: RDTextureFormat
var image_rid: RID
var image_uniform: RDUniform
var push_constant: PackedByteArray
var output_format: RDTextureFormat
var output_rid: RID
var output_uniform: RDUniform

var image_uniform_rid: RID
var output_uniform_rid: RID
var pipeline: RID


func _init() -> void:
    for i in range(4):
        noise_channels.append(FastNoiseLite.new())


func _ready() -> void:
    set_shader_version.call_deferred(initial_shader_version)


func set_shader_version(version: String) -> void:
    var shader_file_contents: RDShaderFile = load(shader_file)
    var shader_spirv: RDShaderSPIRV = shader_file_contents.get_spirv(version)
    rd = RenderingServer.create_local_rendering_device()
    shader = rd.shader_create_from_spirv(shader_spirv)


@warning_ignore("INTEGER_DIVISION")
func build_params(
    section: Vector4i = Vector4i(0, 0, CommonValues.IMAGE_SIZE / 2, CommonValues.IMAGE_SIZE / 2),
    target: Vector2i = Vector2i(0, 0),
    flags: int = 0,
    glow_strength: float = 1.0,
    glow_bloom: float = 1.0,
    glow_hdr_threshold: float = 1.0,
    glow_hdr_scale: float = 1.0,
    glow_exposure: float = 1.0,
    glow_luminance_cap: float = 1.0) -> PackedByteArray:
    if not flags and CommonValues.FIRST_GLOW_PASS:
        flags = 1 << 4

    var params: PackedByteArray = PackedByteArray()

    var data_size: int = 0
    data_size += 16 # ivec4 section
    data_size += 8 # ivec2 target
    data_size += 4 # uint flags
    data_size += 4 # float luminance_multiplier
    # // Glow.
    data_size += 4 # float glow_strength
    data_size += 4 # float glow_bloom
    data_size += 4 # float glow_hdr_threshold
    data_size += 4 # float glow_hdr_scale

    data_size += 4 # float glow_exposure
    data_size += 4 # float glow_white
    data_size += 4 # float glow_luminance_cap
    data_size += 4 # float glow_auto_exposure_scale
    # // DOF.
    data_size += 4 # float camera_z_far
    data_size += 4 # float camera_z_near
    # // Octmap.
    data_size += 8 # vec2 octmap_border_size

    data_size += 16 # vec4 set_color

    params.resize(data_size)
    params.encode_s32(0, section.x) # start section
    params.encode_s32(4, section.y)
    params.encode_s32(8, section.z)
    params.encode_s32(12, section.w) # end section

    params.encode_s32(16, target.x) # start target
    params.encode_s32(20, target.y) # end target
    params.encode_u32(24, flags) # flags

    params.encode_float(28, 1.) # float luminance_multiplier

    params.encode_float(32, glow_strength) # float glow_strength
    params.encode_float(36, glow_bloom) # float glow_bloom
    params.encode_float(40, glow_hdr_threshold) # float glow_hdr_threshold
    params.encode_float(44, glow_hdr_scale) # float glow_hdr_scale

    params.encode_float(48, glow_exposure) # float glow_exposure
    params.encode_float(52, 1.) # float glow_white
    params.encode_float(56, glow_luminance_cap) # float glow_luminance_cap
    params.encode_float(60, 1.) # float glow_auto_exposure_scale

    params.encode_float(64, 1.) # float camera_z_far
    params.encode_float(68, 1.) # float camera_z_near

    params.encode_float(72, 1.) # start octmap_border_size
    params.encode_float(76, 1.) # end  octmap_border_size

    params.encode_float(80, 1.) # start set_color
    params.encode_float(84, 1.)
    params.encode_float(88, 1.)
    params.encode_float(92, 1.) # end set_color
    return params

func _initialize_pipeline(im: Image, shader_version: String) -> void:
    set_shader_version(shader_version)
    image = im.duplicate()
    image_rect.texture = ImageTexture.create_from_image(image)

    sampler_state = RDSamplerState.new()
    sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER
    sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER
    sampler_rid = rd.sampler_create(sampler_state)

    image_format = RDTextureFormat.new()
    image_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
    image_format.width = CommonValues.IMAGE_SIZE
    image_format.height = CommonValues.IMAGE_SIZE
    image_format.usage_bits = \
            RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | \
            RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | \
            RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
    image_rid = rd.texture_create(image_format, RDTextureView.new(), [image.get_data()])

    image_uniform = RDUniform.new()
    image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
    image_uniform.binding = 0
    image_uniform.add_id(sampler_rid)
    image_uniform.add_id(image_rid)

    push_constant = build_params()

    output_format = RDTextureFormat.new()
    output_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
    @warning_ignore("INTEGER_DIVISION")
    output_format.width = CommonValues.IMAGE_SIZE / 2
    @warning_ignore("INTEGER_DIVISION")
    output_format.height = CommonValues.IMAGE_SIZE / 2

    output_format.usage_bits = \
            RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | \
            RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | \
            RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

    output_rid = rd.texture_create(output_format, RDTextureView.new())

    output_uniform = RDUniform.new()
    output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    output_uniform.binding = 0
    output_uniform.add_id(output_rid)

    image_uniform_rid = rd.uniform_set_create([image_uniform], shader, 0)
    output_uniform_rid = rd.uniform_set_create([output_uniform], shader, 3)
    pipeline = rd.compute_pipeline_create(shader)


func execute_benchmark(display_image: bool = false) -> void:
    rd.submit()
    rd.sync ()

    var compute_list: int = rd.compute_list_begin()
    rd.capture_timestamp("start_calc")
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
    rd.compute_list_bind_uniform_set(compute_list, image_uniform_rid, 0)
    rd.compute_list_bind_uniform_set(compute_list, output_uniform_rid, 3)
    rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
    for i in range(SAMPLE_ITERATIONS):
        rd.compute_list_dispatch(compute_list, workgroups_x, workgroups_y, 1)
    rd.compute_list_end()
    rd.capture_timestamp("stop_calc")

    rd.submit()
    rd.sync ()

    var delta: int = rd.get_captured_timestamp_gpu_time(1) - rd.get_captured_timestamp_gpu_time(0)
    var average_execution_time: float = delta / (SAMPLE_ITERATIONS * 1000.0)

    var output_bytes: PackedByteArray = rd.texture_get_data(output_rid, 0).duplicate()
    
    @warning_ignore("INTEGER_DIVISION")
    var output_image := Image.create_from_data(
        CommonValues.IMAGE_SIZE / 2,
        CommonValues.IMAGE_SIZE / 2,
        false,
        Image.FORMAT_RGBA8,
        output_bytes
    )

    if display_image:
        output_rect.texture = ImageTexture.create_from_image(output_image)

    CommonValues._post_execute(average_execution_time, output_image)
