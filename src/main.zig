const std = @import("std");
const wayland = @import("zig-nriframework/src/wayland_window.zig");
const nriframework = @import("zig-nriframework/src/nriframework.zig");

const MAX_FRAMES_IN_FLIGHT = 3;
const SWAPCHAIN_TEXTURE_NUM = 3;

const QueuedFrame = struct {
    command_allocator: ?*nriframework.c.NriCommandAllocator = null,
    command_buffer: ?*nriframework.c.NriCommandBuffer = null,
};

const SwapChainTexture = struct {
    acquire_semaphore: ?*nriframework.c.NriFence = null,
    release_semaphore: ?*nriframework.c.NriFence = null,
    texture: ?*nriframework.c.NriTexture = null,
    color_attachment: ?*nriframework.c.NriDescriptor = null, // color attachment view
    attachment_format: u32 = 0, // for validation/debug
    layout: nriframework.c.NriAccessLayoutStage = nriframework.c.NriAccessLayoutStage{
        .access = nriframework.c.NriAccessBits_UNKNOWN,
        .layout = nriframework.c.NriLayout_UNKNOWN,
    },
    frame_fence: ?*nriframework.c.NriFence = null, // Per-image fence for CPU-GPU sync
};

const Sample = struct {
    device: *nriframework.c.NriDevice,
    nri: nriframework.NRIInterface,
    window: wayland.WaylandWindow,
    queue: *nriframework.c.NriQueue,
    swapchain: *nriframework.c.NriSwapChain,
    // Raytracing resources
    frames: [MAX_FRAMES_IN_FLIGHT]QueuedFrame = undefined,
    swapchain_textures: [SWAPCHAIN_TEXTURE_NUM]SwapChainTexture = undefined,
    // Removed per-frame acquire/release semaphores from Sample
    pipeline: ?*nriframework.c.NriPipeline = null,
    pipeline_layout: ?*nriframework.c.NriPipelineLayout = null,
    descriptor_pool: ?*nriframework.c.NriDescriptorPool = null,
    descriptor_set: ?*nriframework.c.NriDescriptorSet = null,
    raytracing_output: ?*nriframework.c.NriTexture = null,
    raytracing_output_view: ?*nriframework.c.NriDescriptor = null,
    blas: ?*nriframework.c.NriAccelerationStructure = null,
    tlas: ?*nriframework.c.NriAccelerationStructure = null,
    tlas_descriptor: ?*nriframework.c.NriDescriptor = null,
    shader_table: ?*nriframework.c.NriBuffer = null,
    shader_table_memory: ?*nriframework.c.NriMemory = null,
    // Offsets for shader table dispatch
    shader_table_raygen_offset: u64 = 0,
    shader_table_miss_offset: u64 = 0,
    shader_table_hit_offset: u64 = 0,
    shader_table_stride: usize = 0,
    // Removed global frame_fence; now per-image
};

// Helper: align to 4 bytes (Vulkan SPIR-V requirement)
fn align4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

// Helper: pad shader code to 4 bytes as required by Vulkan
fn pad_shader(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    const padded_len = align4(code.len);
    var buf = try allocator.alloc(u8, padded_len);
    std.mem.copyForwards(u8, buf[0..code.len], code);
    if (padded_len > code.len) {
        for (buf[code.len..]) |*b| b.* = 0;
    }
    return buf;
}

// Helper: align to arbitrary alignment (for shader table alignment)
fn align_up(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn create_swapchain_textures(sample: *Sample) !void {
    // Query swapchain textures from NRI
    var texture_num: u32 = 0;
    const textures = sample.nri.swapchain.GetSwapChainTextures.?(sample.swapchain, &texture_num);
    if (textures == null or texture_num == 0) return error.NRISwapChainTexturesFailed;
    if (texture_num > SWAPCHAIN_TEXTURE_NUM) return error.TooManySwapchainTextures;
    // Create color attachment views and per-image fences for each swapchain image
    for (sample.swapchain_textures[0..texture_num], 0..) |*sct, i| {
        // Create color attachment view
        var view_desc = nriframework.c.NriTexture2DViewDesc{
            .texture = textures[i],
            .viewType = nriframework.c.NriTexture2DViewType_COLOR_ATTACHMENT,
            .format = nriframework.c.NriFormat_RGBA8_UNORM, // match swapchain format
        };
        var color_attachment: ?*nriframework.c.NriDescriptor = null;
        if (sample.nri.core.CreateTexture2DView.?(&view_desc, &color_attachment) != nriframework.c.NriResult_SUCCESS or color_attachment == null)
            return error.NRICreateSwapchainTextureViewFailed;
        // Create per-image fence
        var frame_fence: ?*nriframework.c.NriFence = null;
        if (sample.nri.core.CreateFence.?(sample.device, 0, &frame_fence) != nriframework.c.NriResult_SUCCESS or frame_fence == null)
            return error.NRICreateFrameFenceFailed;
        // Create per-image acquire and release semaphores
        var acquire_semaphore: ?*nriframework.c.NriFence = null;
        if (sample.nri.core.CreateFence.?(sample.device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &acquire_semaphore) != nriframework.c.NriResult_SUCCESS or acquire_semaphore == null)
            return error.NRICreateAcquireSemaphoreFailed;
        var release_semaphore: ?*nriframework.c.NriFence = null;
        if (sample.nri.core.CreateFence.?(sample.device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &release_semaphore) != nriframework.c.NriResult_SUCCESS or release_semaphore == null)
            return error.NRICreateReleaseSemaphoreFailed;
        sct.* = SwapChainTexture{
            .texture = textures[i],
            .color_attachment = color_attachment,
            .attachment_format = nriframework.c.NriFormat_RGBA8_UNORM,
            .layout = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_UNKNOWN,
            },
            .frame_fence = frame_fence,
            .acquire_semaphore = acquire_semaphore,
            .release_semaphore = release_semaphore,
        };
    }
    // Zero out any unused slots (if any)
    for (sample.swapchain_textures[texture_num..]) |*sct| {
        sct.* = SwapChainTexture{
            .texture = null,
            .color_attachment = null,
            .attachment_format = 0,
            .frame_fence = null,
        };
    }
}

fn create_raytracing_pipeline(sample: *Sample, rgen_shader: []const u8, rmiss_shader: []const u8, rchit_shader: []const u8) !void {
    // Descriptor ranges: STORAGE_TEXTURE (output), ACCELERATION_STRUCTURE (TLAS)
    var descriptor_ranges = [2]nriframework.c.NriDescriptorRangeDesc{
        .{ // Output texture
            .descriptorNum = 1,
            .descriptorType = nriframework.c.NriDescriptorType_STORAGE_TEXTURE,
            .baseRegisterIndex = 0,
            .shaderStages = nriframework.c.NriStageBits_RAYGEN_SHADER,
        },
        .{ // TLAS
            .descriptorNum = 1,
            .descriptorType = nriframework.c.NriDescriptorType_ACCELERATION_STRUCTURE,
            .baseRegisterIndex = 1,
            .shaderStages = nriframework.c.NriStageBits_RAYGEN_SHADER,
        },
    };
    var descriptor_set_desc = nriframework.c.NriDescriptorSetDesc{
        .ranges = &descriptor_ranges,
        .rangeNum = 2,
    };
    var pipeline_layout_desc = nriframework.c.NriPipelineLayoutDesc{
        .descriptorSets = &descriptor_set_desc,
        .descriptorSetNum = 1,
        .shaderStages = nriframework.c.NriStageBits_RAYGEN_SHADER,
    };
    var pipeline_layout: ?*nriframework.c.NriPipelineLayout = null;
    if (sample.nri.core.CreatePipelineLayout.?(sample.device, &pipeline_layout_desc, &pipeline_layout) != nriframework.c.NriResult_SUCCESS or pipeline_layout == null)
        return error.NRICreatePipelineLayoutFailed;
    sample.pipeline_layout = pipeline_layout;
    // Load shaders from memory, ensure codeSize is a multiple of 4 (Vulkan spec)
    const padded_rgen = try pad_shader(std.heap.c_allocator, rgen_shader);
    defer if (padded_rgen.ptr != rgen_shader.ptr) std.heap.c_allocator.free(padded_rgen);
    const padded_rmiss = try pad_shader(std.heap.c_allocator, rmiss_shader);
    defer if (padded_rmiss.ptr != rmiss_shader.ptr) std.heap.c_allocator.free(padded_rmiss);
    const padded_rchit = try pad_shader(std.heap.c_allocator, rchit_shader);
    defer if (padded_rchit.ptr != rchit_shader.ptr) std.heap.c_allocator.free(padded_rchit);
    var shaders = [3]nriframework.c.NriShaderDesc{
        .{ .stage = nriframework.c.NriStageBits_RAYGEN_SHADER, .bytecode = padded_rgen.ptr, .size = padded_rgen.len, .entryPointName = "raygen" },
        .{ .stage = nriframework.c.NriStageBits_MISS_SHADER, .bytecode = padded_rmiss.ptr, .size = padded_rmiss.len, .entryPointName = "miss" },
        .{ .stage = nriframework.c.NriStageBits_CLOSEST_HIT_SHADER, .bytecode = padded_rchit.ptr, .size = padded_rchit.len, .entryPointName = "closest_hit" },
    };
    var shader_library = nriframework.c.NriShaderLibraryDesc{
        .shaders = &shaders,
        .shaderNum = 3,
    };
    var shader_groups = [3]nriframework.c.NriShaderGroupDesc{
        .{ .shaderIndices = .{ 1, 0, 0 } }, // raygen
        .{ .shaderIndices = .{ 2, 0, 0 } }, // miss
        .{ .shaderIndices = .{ 3, 0, 0 } }, // hit
    };
    var pipeline_desc = nriframework.c.NriRayTracingPipelineDesc{
        .recursionMaxDepth = 1,
        .rayPayloadMaxSize = 3 * @sizeOf(f32),
        .rayHitAttributeMaxSize = 2 * @sizeOf(f32),
        .pipelineLayout = pipeline_layout,
        .shaderGroups = &shader_groups,
        .shaderGroupNum = 3,
        .shaderLibrary = &shader_library,
    };
    var pipeline: ?*nriframework.c.NriPipeline = null;
    if (sample.nri.raytracing.CreateRayTracingPipeline.?(sample.device, &pipeline_desc, &pipeline) != nriframework.c.NriResult_SUCCESS or pipeline == null)
        return error.NRICreateRayTracingPipelineFailed;
    sample.pipeline = pipeline;
}

fn create_raytracing_output(sample: *Sample) !void {
    // Output texture for raytracing result
    var output_desc = nriframework.c.NriTextureDesc{
        .type = nriframework.c.NriTextureType_TEXTURE_2D,
        .format = nriframework.c.NriFormat_RGBA8_UNORM, // Use RGBA8_UNORM for raytracing output
        .width = @intCast(sample.window.width),
        .height = @intCast(sample.window.height),
        .depth = 1,
        .layerNum = 1,
        .mipNum = 1,
        .sampleNum = 1,
        .usage = nriframework.c.NriTextureUsageBits_SHADER_RESOURCE_STORAGE,
    };
    var output: ?*nriframework.c.NriTexture = null;
    if (sample.nri.core.CreateTexture.?(sample.device, &output_desc, &output) != nriframework.c.NriResult_SUCCESS or output == null)
        return error.NRICreateRayTracingOutputFailed;
    sample.raytracing_output = output;
    // Allocate/bind memory
    var mem_desc: nriframework.c.NriMemoryDesc = undefined;
    sample.nri.core.GetTextureMemoryDesc.?(output, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
    var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
        .size = mem_desc.size,
        .type = mem_desc.type,
    };
    var memory: ?*nriframework.c.NriMemory = null;
    if (sample.nri.core.AllocateMemory.?(sample.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
        return error.NRIAllocateRayTracingOutputMemoryFailed;
    var binding = nriframework.c.NriTextureMemoryBindingDesc{
        .texture = output,
        .memory = memory,
    };
    if (sample.nri.core.BindTextureMemory.?(sample.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBindRayTracingOutputMemoryFailed;
    // Create view/descriptor
    var view_desc = nriframework.c.NriTexture2DViewDesc{
        .texture = output,
        .viewType = nriframework.c.NriTexture2DViewType_SHADER_RESOURCE_STORAGE_2D,
        .format = nriframework.c.NriFormat_RGBA8_UNORM, // Use RGBA8_UNORM for the view as well
    };
    var output_view: ?*nriframework.c.NriDescriptor = null;
    if (sample.nri.core.CreateTexture2DView.?(&view_desc, &output_view) != nriframework.c.NriResult_SUCCESS or output_view == null)
        return error.NRICreateRayTracingOutputViewFailed;
    sample.raytracing_output_view = output_view;
}

fn create_descriptor_set(sample: *Sample) !void {
    // Pool
    var pool_desc = nriframework.c.NriDescriptorPoolDesc{
        .storageTextureMaxNum = 1,
        .accelerationStructureMaxNum = 1,
        .descriptorSetMaxNum = 1,
    };
    var pool: ?*nriframework.c.NriDescriptorPool = null;
    if (sample.nri.core.CreateDescriptorPool.?(sample.device, &pool_desc, &pool) != nriframework.c.NriResult_SUCCESS or pool == null)
        return error.NRICreateDescriptorPoolFailed;
    sample.descriptor_pool = pool;
    // Set
    var set: ?*nriframework.c.NriDescriptorSet = null;
    if (sample.nri.core.AllocateDescriptorSets.?(pool, sample.pipeline_layout, 0, &set, 1, 0) != nriframework.c.NriResult_SUCCESS or set == null)
        return error.NRIAllocateDescriptorSetFailed;
    sample.descriptor_set = set;
    // Bind output texture view
    var range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
        .descriptors = &sample.raytracing_output_view,
        .descriptorNum = 1,
        .baseDescriptor = 0,
    };
    sample.nri.core.UpdateDescriptorRanges.?(set, 0, 1, &range_update);
}

fn create_blas_tlas(sample: *Sample) !void {
    // --- BLAS ---
    const vertex_data = [_]f32{ -0.5, -0.5, 0.0, 0.0, 0.5, 0.0, 0.5, -0.5, 0.0 };
    const index_data = [_]u16{ 0, 1, 2 };
    const vertex_data_size = @sizeOf(@TypeOf(vertex_data));
    const index_data_size = @sizeOf(@TypeOf(index_data));
    // Upload buffer for BLAS
    var upload_buffer: ?*nriframework.c.NriBuffer = null;
    var upload_memory: ?*nriframework.c.NriMemory = null;
    try create_upload_buffer(sample, vertex_data_size + index_data_size, nriframework.c.NriBufferUsageBits_ACCELERATION_STRUCTURE_BUILD_INPUT, &upload_buffer, &upload_memory);
    // Map and copy data
    const data_ptr = sample.nri.core.MapBuffer.?(upload_buffer, 0, vertex_data_size + index_data_size);
    const vertex_bytes = std.mem.sliceAsBytes(&vertex_data);
    const index_bytes = std.mem.sliceAsBytes(&index_data);
    const data_slice = @as([*]u8, @ptrCast(data_ptr))[0 .. vertex_data_size + index_data_size];
    std.mem.copyForwards(u8, data_slice[0..vertex_bytes.len], vertex_bytes);
    std.mem.copyForwards(u8, data_slice[vertex_bytes.len .. vertex_bytes.len + index_bytes.len], index_bytes);
    sample.nri.core.UnmapBuffer.?(upload_buffer);
    // BLAS desc
    var geometry = nriframework.c.NriBottomLevelGeometryDesc{
        .type = nriframework.c.NriBottomLevelGeometryType_TRIANGLES,
        .flags = nriframework.c.NriBottomLevelGeometryBits_OPAQUE_GEOMETRY,
        .unnamed_0 = .{
            .triangles = nriframework.c.NriBottomLevelTrianglesDesc{
                .vertexBuffer = upload_buffer,
                .vertexFormat = nriframework.c.NriFormat_RGB32_SFLOAT,
                .vertexNum = 3,
                .vertexStride = 3 * @sizeOf(f32),
                .indexBuffer = upload_buffer,
                .indexOffset = vertex_data_size,
                .indexNum = 3,
                .indexType = nriframework.c.NriIndexType_UINT16,
            },
        },
    };
    var blas_desc = nriframework.c.NriAccelerationStructureDesc{
        .type = nriframework.c.NriAccelerationStructureType_BOTTOM_LEVEL,
        .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
        .geometryOrInstanceNum = 1,
        .geometries = &geometry,
    };
    var blas: ?*nriframework.c.NriAccelerationStructure = null;
    if (sample.nri.raytracing.CreateAccelerationStructure.?(sample.device, &blas_desc, &blas) != nriframework.c.NriResult_SUCCESS or blas == null)
        return error.NRICreateBLASFailed;
    sample.blas = blas;
    // Allocate/bind memory
    var blas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
    sample.nri.raytracing.GetAccelerationStructureMemoryDesc.?(blas, nriframework.c.NriMemoryLocation_DEVICE, &blas_mem_desc);
    var blas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
        .size = blas_mem_desc.size,
        .type = blas_mem_desc.type,
    };
    var blas_memory: ?*nriframework.c.NriMemory = null;
    if (sample.nri.core.AllocateMemory.?(sample.device, &blas_alloc_desc, &blas_memory) != nriframework.c.NriResult_SUCCESS or blas_memory == null)
        return error.NRIAllocateBLASMemoryFailed;
    var blas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
        .accelerationStructure = blas,
        .memory = blas_memory,
    };
    if (sample.nri.raytracing.BindAccelerationStructureMemory.?(sample.device, &blas_binding, 1) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBindBLASMemoryFailed;
    // Build BLAS (stub: see C++ for full command buffer logic)
    // ...
    // Destroy upload buffer
    sample.nri.core.DestroyBuffer.?(upload_buffer);
    sample.nri.core.FreeMemory.?(upload_memory);
    // --- TLAS ---
    var tlas_desc = nriframework.c.NriAccelerationStructureDesc{
        .type = nriframework.c.NriAccelerationStructureType_TOP_LEVEL,
        .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
        .geometryOrInstanceNum = 1,
        .geometries = null,
    };
    var tlas: ?*nriframework.c.NriAccelerationStructure = null;
    if (sample.nri.raytracing.CreateAccelerationStructure.?(sample.device, &tlas_desc, &tlas) != nriframework.c.NriResult_SUCCESS or tlas == null)
        return error.NRICreateTLASFailed;
    sample.tlas = tlas;
    // Allocate/bind memory for TLAS
    var tlas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
    sample.nri.raytracing.GetAccelerationStructureMemoryDesc.?(tlas, nriframework.c.NriMemoryLocation_DEVICE, &tlas_mem_desc);
    var tlas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
        .size = tlas_mem_desc.size,
        .type = tlas_mem_desc.type,
    };
    var tlas_memory: ?*nriframework.c.NriMemory = null;
    if (sample.nri.core.AllocateMemory.?(sample.device, &tlas_alloc_desc, &tlas_memory) != nriframework.c.NriResult_SUCCESS or tlas_memory == null)
        return error.NRIAllocateTLASMemoryFailed;
    var tlas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
        .accelerationStructure = tlas,
        .memory = tlas_memory,
    };
    if (sample.nri.raytracing.BindAccelerationStructureMemory.?(sample.device, &tlas_binding, 1) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBindTLASMemoryFailed;
    // Instance buffer for TLAS
    var instance_buffer: ?*nriframework.c.NriBuffer = null;
    var instance_memory: ?*nriframework.c.NriMemory = null;
    try create_upload_buffer(sample, nriframework.NRI_TOP_LEVEL_INSTANCE_SIZE, nriframework.c.NriBufferUsageBits_ACCELERATION_STRUCTURE_BUILD_INPUT, &instance_buffer, &instance_memory);
    const inst_ptr = sample.nri.core.MapBuffer.?(instance_buffer, 0, nriframework.NRI_TOP_LEVEL_INSTANCE_SIZE);
    const inst_slice = @as([*]u8, @ptrCast(inst_ptr))[0..nriframework.NRI_TOP_LEVEL_INSTANCE_SIZE];
    for (inst_slice) |*b| b.* = 0;
    sample.nri.core.UnmapBuffer.?(instance_buffer);
    // Build TLAS (stub: see C++ for full command buffer logic)
    // ...
    // Create TLAS descriptor
    var tlas_desc_ptr: ?*nriframework.c.NriDescriptor = null;
    if (sample.nri.raytracing.CreateAccelerationStructureDescriptor.?(tlas, &tlas_desc_ptr) != nriframework.c.NriResult_SUCCESS or tlas_desc_ptr == null)
        return error.NRICreateTLASDescriptorFailed;
    sample.tlas_descriptor = tlas_desc_ptr;
    // Bind TLAS descriptor to descriptor set
    var tlas_range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
        .descriptors = &tlas_desc_ptr,
        .descriptorNum = 1,
        .baseDescriptor = 0,
    };
    sample.nri.core.UpdateDescriptorRanges.?(sample.descriptor_set, 1, 1, &tlas_range_update);

    // Destroy instance buffer
    sample.nri.core.DestroyBuffer.?(instance_buffer);
    sample.nri.core.FreeMemory.?(instance_memory);
}

fn create_upload_buffer(sample: *Sample, size: usize, usage: u32, buffer_out: *?*nriframework.c.NriBuffer, memory_out: *?*nriframework.c.NriMemory) !void {
    var desc = nriframework.c.NriBufferDesc{
        .size = size,
        .structureStride = 0,
        .usage = @intCast(usage),
    };
    var buffer: ?*nriframework.c.NriBuffer = null;
    if (sample.nri.core.CreateBuffer.?(sample.device, &desc, &buffer) != nriframework.c.NriResult_SUCCESS or buffer == null)
        return error.NRICreateUploadBufferFailed;
    var mem_desc: nriframework.c.NriMemoryDesc = undefined;
    sample.nri.core.GetBufferMemoryDesc.?(buffer, nriframework.c.NriMemoryLocation_HOST_UPLOAD, &mem_desc);
    var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
        .size = mem_desc.size,
        .type = mem_desc.type,
    };
    var memory: ?*nriframework.c.NriMemory = null;
    if (sample.nri.core.AllocateMemory.?(sample.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
        return error.NRIAllocateUploadBufferMemoryFailed;
    var binding = nriframework.c.NriBufferMemoryBindingDesc{
        .buffer = buffer,
        .memory = memory,
    };
    if (sample.nri.core.BindBufferMemory.?(sample.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBindUploadBufferMemoryFailed;
    buffer_out.* = buffer;
    memory_out.* = memory;
}

fn create_shader_table(sample: *Sample) !void {
    // Query device desc for identifier size and alignment
    const device_desc = sample.nri.core.GetDeviceDesc.?(sample.device);
    const identifier_size: usize = device_desc.*.shaderStage.rayTracing.shaderGroupIdentifierSize;
    const alignment: usize = device_desc.*.memoryAlignment.shaderBindingTable;
    // Calculate aligned offsets and total size
    const raygen_offset = 0;
    const miss_offset = align_up(raygen_offset + identifier_size, alignment);
    const hit_offset = align_up(miss_offset + identifier_size, alignment);
    const total_size = align_up(hit_offset + identifier_size, alignment);
    // Allocate buffer for shader table
    var shader_table_desc = nriframework.c.NriBufferDesc{
        .size = total_size,
        .structureStride = 0,
        .usage = nriframework.c.NriBufferUsageBits_SHADER_BINDING_TABLE,
    };
    var shader_table: ?*nriframework.c.NriBuffer = null;
    if (sample.nri.core.CreateBuffer.?(sample.device, &shader_table_desc, &shader_table) != nriframework.c.NriResult_SUCCESS or shader_table == null)
        return error.NRICreateShaderTableFailed;
    sample.shader_table = shader_table;
    // Allocate/bind memory
    var mem_desc: nriframework.c.NriMemoryDesc = undefined;
    sample.nri.core.GetBufferMemoryDesc.?(shader_table, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
    var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
        .size = mem_desc.size,
        .type = mem_desc.type,
    };
    var memory: ?*nriframework.c.NriMemory = null;
    if (sample.nri.core.AllocateMemory.?(sample.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
        return error.NRIAllocateShaderTableMemoryFailed;
    var binding = nriframework.c.NriBufferMemoryBindingDesc{
        .buffer = shader_table,
        .memory = memory,
    };
    if (sample.nri.core.BindBufferMemory.?(sample.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBindShaderTableMemoryFailed;
    sample.shader_table_memory = memory;
    // Store offsets for use in dispatch
    sample.shader_table_raygen_offset = raygen_offset;
    sample.shader_table_miss_offset = miss_offset;
    sample.shader_table_hit_offset = hit_offset;
    sample.shader_table_stride = identifier_size;

    // Write shader group identifiers at aligned offsets (required for Vulkan/NRI)
    // Map a temporary upload buffer, write identifiers, then copy to device buffer if needed
    // (Assume NRI WriteShaderGroupIdentifiers is available via sample.nri.raytracing.WriteShaderGroupIdentifiers)
    // Map buffer
    const upload_buffer_size = total_size;
    var upload_buffer: ?*nriframework.c.NriBuffer = null;
    var upload_memory: ?*nriframework.c.NriMemory = null;
    try create_upload_buffer(sample, upload_buffer_size, 0, &upload_buffer, &upload_memory);
    const data_ptr = sample.nri.core.MapBuffer.?(upload_buffer, 0, upload_buffer_size);
    const data_slice = @as([*]u8, @ptrCast(data_ptr))[0..upload_buffer_size];
    // Zero out buffer
    for (data_slice) |*b| b.* = 0;
    // Write identifiers at aligned offsets
    if (sample.nri.raytracing.WriteShaderGroupIdentifiers) |WriteShaderGroupIdentifiers| {
        _ = WriteShaderGroupIdentifiers(sample.pipeline, 0, 1, &data_slice[raygen_offset]);
        _ = WriteShaderGroupIdentifiers(sample.pipeline, 1, 1, &data_slice[miss_offset]);
        _ = WriteShaderGroupIdentifiers(sample.pipeline, 2, 1, &data_slice[hit_offset]);
    }
    sample.nri.core.UnmapBuffer.?(upload_buffer);
    // Copy upload buffer to device-local shader table buffer
    // (You may need to record a command buffer for this copy, as in the C++ sample)
    // ...
}

fn record_and_submit(sample: *Sample, frame_index: u32, image_index: u32) !void {
    // Begin command buffer
    var frame = &sample.frames[frame_index % MAX_FRAMES_IN_FLIGHT];
    // Reset command allocator before recording each frame
    sample.nri.core.ResetCommandAllocator.?(frame.command_allocator);

    if (sample.nri.core.BeginCommandBuffer.?(frame.command_buffer, sample.descriptor_pool) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBeginCommandBufferFailed;

    // Resource barriers: transition swapchain image to COPY_DESTINATION for writing
    const swapchain_tex = &sample.swapchain_textures[image_index];
    // 1. Transition swapchain image to COPY_DESTINATION (for copy from raytracing output)
    const barrier_to_copy_dst = nriframework.c.NriTextureBarrierDesc{
        .texture = swapchain_tex.texture,
        .before = nriframework.c.NriAccessLayoutStage{
            .access = swapchain_tex.layout.access,
            .layout = swapchain_tex.layout.layout,
        },
        .after = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_COPY_DESTINATION,
            .layout = nriframework.c.NriLayout_COPY_DESTINATION,
        },
        .mipNum = 1,
        .mipOffset = 0,
    };
    // 2. Transition raytracing output to SHADER_RESOURCE_STORAGE for dispatch, then to COPY_SOURCE for copy
    const barrier_rt_output_to_shader = nriframework.c.NriTextureBarrierDesc{
        .texture = sample.raytracing_output,
        .before = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_UNKNOWN,
            .layout = nriframework.c.NriLayout_UNKNOWN,
        },
        .after = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_SHADER_RESOURCE_STORAGE,
            .layout = nriframework.c.NriLayout_SHADER_RESOURCE_STORAGE,
        },
        .mipNum = 1,
        .mipOffset = 0,
    };
    var barrier_group1 = [2]nriframework.c.NriTextureBarrierDesc{ barrier_to_copy_dst, barrier_rt_output_to_shader };
    var barrier_desc1 = nriframework.c.NriBarrierGroupDesc{
        .textureNum = 2,
        .textures = &barrier_group1,
        .bufferNum = 0,
        .buffers = null,
    };
    sample.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc1);
    // After transition, update tracked layout
    swapchain_tex.layout = nriframework.c.NriAccessLayoutStage{
        .access = nriframework.c.NriAccessBits_COPY_DESTINATION,
        .layout = nriframework.c.NriLayout_COPY_DESTINATION,
    };

    // --- Raytracing dispatch ---
    // Bind pipeline layout, pipeline, and descriptor set before dispatch (required by Vulkan)
    sample.nri.core.CmdSetPipelineLayout.?(frame.command_buffer, sample.pipeline_layout);
    sample.nri.core.CmdSetPipeline.?(frame.command_buffer, sample.pipeline);
    sample.nri.core.CmdSetDescriptorSet.?(frame.command_buffer, 0, sample.descriptor_set, null);

    const device_desc = sample.nri.core.GetDeviceDesc.?(sample.device);
    const identifier_size: usize = device_desc.*.shaderStage.rayTracing.shaderGroupIdentifierSize;

    const raygen_offset: u64 = sample.shader_table_raygen_offset;
    const miss_offset: u64 = sample.shader_table_miss_offset;
    const hit_offset: u64 = sample.shader_table_hit_offset;
    var dispatch_desc = nriframework.c.NriDispatchRaysDesc{
        .raygenShader = .{
            .buffer = sample.shader_table,
            .offset = raygen_offset,
            .size = identifier_size,
            .stride = identifier_size,
        },
        .missShaders = nriframework.c.NriStridedBufferRegion{
            .buffer = sample.shader_table,
            .offset = miss_offset,
            .size = identifier_size,
            .stride = identifier_size,
        },
        .hitShaderGroups = nriframework.c.NriStridedBufferRegion{
            .buffer = sample.shader_table,
            .offset = hit_offset,
            .size = identifier_size,
            .stride = identifier_size,
        },
        .x = @intCast(sample.window.width),
        .y = @intCast(sample.window.height),
        .z = 1,
    };
    sample.nri.raytracing.CmdDispatchRays.?(frame.command_buffer, &dispatch_desc);

    // 3. Transition raytracing output to COPY_SOURCE for copy to swapchain
    const barrier_rt_output_to_copy_src = nriframework.c.NriTextureBarrierDesc{
        .texture = sample.raytracing_output,
        .before = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_SHADER_RESOURCE_STORAGE,
            .layout = nriframework.c.NriLayout_SHADER_RESOURCE_STORAGE,
        },
        .after = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_COPY_SOURCE,
            .layout = nriframework.c.NriLayout_COPY_SOURCE,
        },
        .mipNum = 1,
        .mipOffset = 0,
    };
    var barrier_desc2 = nriframework.c.NriBarrierGroupDesc{
        .textureNum = 1,
        .textures = &barrier_rt_output_to_copy_src,
        .bufferNum = 0,
        .buffers = null,
    };
    sample.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc2);
    // After transition, update tracked layout
    //sample.raytracing_output_layout = nriframework.c.NriAccessLayoutStage{
    //    .access = nriframework.c.NriAccessBits_COPY_SOURCE,
    //    .layout = nriframework.c.NriLayout_COPY_SOURCE,
    //};

    sample.nri.core.CmdCopyTexture.?(frame.command_buffer, swapchain_tex.texture, null, sample.raytracing_output, null);
    // 4. Transition swapchain image to PRESENT for presentation
    const barrier_to_present = nriframework.c.NriTextureBarrierDesc{
        .texture = swapchain_tex.texture,
        .before = nriframework.c.NriAccessLayoutStage{
            .access = swapchain_tex.layout.access,
            .layout = swapchain_tex.layout.layout,
        },
        .after = nriframework.c.NriAccessLayoutStage{
            .access = nriframework.c.NriAccessBits_UNKNOWN,
            .layout = nriframework.c.NriLayout_PRESENT,
        },
        .mipNum = 1,
        .mipOffset = 0,
    };
    var barrier_desc_present = nriframework.c.NriBarrierGroupDesc{
        .textureNum = 1,
        .textures = &barrier_to_present,
        .bufferNum = 0,
        .buffers = null,
    };
    sample.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc_present);
    // After transition, update tracked layout
    swapchain_tex.layout = nriframework.c.NriAccessLayoutStage{
        .access = nriframework.c.NriAccessBits_UNKNOWN,
        .layout = nriframework.c.NriLayout_PRESENT,
    };
    // --- END: Ported from raytracing.cpp lines 190-238 ---
    // End command buffer
    if (sample.nri.core.EndCommandBuffer.?(frame.command_buffer) != nriframework.c.NriResult_SUCCESS)
        return error.NRIEndCommandBufferFailed;
    // Submit
    var wait_fence_descs = [_]nriframework.c.NriFenceSubmitDesc{
        .{ .fence = sample.swapchain_textures[frame_index % SWAPCHAIN_TEXTURE_NUM].acquire_semaphore, .stages = nriframework.c.NriStageBits_ALL },
    };
    std.debug.print("Submitting frame {} for image {}\n", .{frame_index, image_index});
    var signal_fence_descs = [_]nriframework.c.NriFenceSubmitDesc{
        .{ .fence = sample.swapchain_textures[image_index].release_semaphore}, // Use per-image release semaphore
        .{ .fence = sample.swapchain_textures[image_index].frame_fence, .value = frame_index + 1 }, // Use frame index as value for CPU-GPU sync
    };
    var submit_desc = nriframework.c.NriQueueSubmitDesc{
        .commandBuffers = &frame.command_buffer,
        .commandBufferNum = 1,
        .waitFences = &wait_fence_descs,
        .waitFenceNum = 1,
        .signalFences = &signal_fence_descs,
        .signalFenceNum = 1,
    };
    sample.nri.core.QueueSubmit.?(sample.queue, &submit_desc);
}

pub fn main() !void {
    // 1. Create the window
    var window = try wayland.createWindow(800, 600);
    defer wayland.destroyWindow(&window);
    // Show the window and poll events to ensure surface is mapped
    window.showWindow();
    wayland.pollEvents(&window);
    // Set up callbacks and user pointer here if needed (see wayland_window.zig)
    // ...
    // 2. Create device
    const device = try nriframework.createDevice(0, true, true);
    defer nriframework.c.nriDestroyDevice(device);
    // 3. Get all NRI interfaces
    var nri: nriframework.NRIInterface = undefined;
    try nriframework.getInterfaces(device, &nri);
    // 4. Get graphics queue
    const queue = try nriframework.getQueue(&nri.core, device, nriframework.c.NriQueueType_GRAPHICS, 0);
    // 5. Create swapchain (uses window.nri_window)
    const swapchain = try nriframework.createSwapChain(&nri.swapchain, device, &window, queue, window.width, window.height, nriframework.c.NriSwapChainFormat_BT709_G22_8BIT, 0);
    defer nri.swapchain.DestroySwapChain.?(swapchain); // Ensures swapchain (and VkSurfaceKHR) destroyed before device
    // 6. Create frame fence for CPU-GPU sync
    // (No global frame_fence or per-image acquire/release semaphores here)
    // 7. Load shaders from disk (SPIR-V bytecode)
    const allocator = std.heap.c_allocator;
    const rgen_shader = try std.fs.cwd().readFileAlloc(allocator, "shaders/RayTracingTriangle.rgen.hlsl.spv", 10 * 1024);
    defer allocator.free(rgen_shader);
    const rmiss_shader = try std.fs.cwd().readFileAlloc(allocator, "shaders/RayTracingTriangle.rmiss.hlsl.spv", 10 * 1024);
    defer allocator.free(rmiss_shader);
    const rchit_shader = try std.fs.cwd().readFileAlloc(allocator, "shaders/RayTracingTriangle.rchit.hlsl.spv", 10 * 1024);
    defer allocator.free(rchit_shader);
    // 8. Sample struct
    var sample = Sample{
        .device = device,
        .nri = nri,
        .window = window,
        .queue = queue,
        .swapchain = swapchain,
        // Remove acquire_semaphores and release_semaphores from Sample
    };
    try create_swapchain_textures(&sample);
    try create_raytracing_pipeline(&sample, rgen_shader, rmiss_shader, rchit_shader);
    try create_raytracing_output(&sample);
    try create_descriptor_set(&sample);
    try create_blas_tlas(&sample);
    try create_shader_table(&sample);
    // Initialize per-frame command allocators and command buffers
    for (0..sample.frames.len) |i| {
        var frame = &sample.frames[i];
        // Create command allocator
        var command_allocator: ?*nriframework.c.NriCommandAllocator = null;
        if (nri.core.CreateCommandAllocator.?(queue, &command_allocator) != nriframework.c.NriResult_SUCCESS or command_allocator == null)
            return error.NRICreateCommandAllocatorFailed;
        frame.command_allocator = command_allocator;
        // Create command buffer
        var command_buffer: ?*nriframework.c.NriCommandBuffer = null;
        if (nri.core.CreateCommandBuffer.?(command_allocator, &command_buffer) != nriframework.c.NriResult_SUCCESS or command_buffer == null)
            return error.NRICreateCommandBufferFailed;
        frame.command_buffer = command_buffer;
    }
    std.debug.print("NRI device, interfaces, queue, swapchain, fence, and resources created!\n", .{});
    var frame_index: u32 = 0;
    var next_acquire_index: u32 = 0;
    while (!sample.window.should_close) {
        wayland.pollEvents(&sample.window);

        // Wait for the fence for the image we are about to acquire
        if (sample.swapchain_textures[next_acquire_index].frame_fence) |fence| {
            nri.core.Wait.?(fence, 1);
        }

        // Acquire next image, passing the acquire_semaphore for this image
        var image_index: u32 = 0;
        try nriframework.acquireNextTexture(
            &sample.nri.swapchain,
            sample.swapchain,
            sample.swapchain_textures[next_acquire_index].acquire_semaphore,
            &image_index
        );
        const swapchain_tex = &sample.swapchain_textures[image_index];

        // Reset command allocator for this frame
        if (sample.frames[frame_index].command_allocator) |ca| sample.nri.core.ResetCommandAllocator.?(ca);

        // Record and submit work for this frame
        try record_and_submit(&sample, frame_index, image_index);

        // Present the current frame, dependent on semaphore signaled by submit
        try nriframework.queuePresent(&sample.nri.swapchain, sample.swapchain, swapchain_tex.release_semaphore);

        // Next frame
        frame_index = (frame_index + 1) % MAX_FRAMES_IN_FLIGHT;
        next_acquire_index = (next_acquire_index + 1) % SWAPCHAIN_TEXTURE_NUM;
        std.time.sleep(16_000_000); // ~60 FPS
    }
    std.debug.print("Window closed.\n", .{});
    // Destroy per-frame command buffers and allocators
    for (0..sample.frames.len) |i| {
        const frame = sample.frames[i];
        if (frame.command_buffer) |cb| sample.nri.core.DestroyCommandBuffer.?(cb);
        if (frame.command_allocator) |ca| sample.nri.core.DestroyCommandAllocator.?(ca);
    }
    // Destroy per-image semaphores and fences
    for (0..SWAPCHAIN_TEXTURE_NUM) |i| {
        if (sample.swapchain_textures[i].acquire_semaphore) |sem| sample.nri.core.DestroyFence.?(sem);
        if (sample.swapchain_textures[i].release_semaphore) |sem| sample.nri.core.DestroyFence.?(sem);
        if (sample.swapchain_textures[i].frame_fence) |fence| sample.nri.core.DestroyFence.?(fence);
    }
}
