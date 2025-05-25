const std = @import("std");
const nriframework = @import("nriframework.zig");
const types = @import("types/index.zig");

/// Raytracing class encapsulating all raytracing resource creation, per-frame logic, and dynamic scene support.
pub const Raytracing = struct {
    allocator: std.mem.Allocator,
    device: *nriframework.c.NriDevice,
    nri: nriframework.NRIInterface,
    queue: *nriframework.c.NriQueue,
    swapchain: *nriframework.c.NriSwapChain,
    frame_fence: ?*nriframework.c.NriFence,
    swapchain_textures: []types.SwapChainTexture,
    frames: []types.QueuedFrame,
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
    shader_table_raygen_offset: u64 = 0,
    shader_table_miss_offset: u64 = 0,
    shader_table_hit_offset: u64 = 0,
    shader_table_stride: usize = 0,
    output_width: u32 = 800,
    output_height: u32 = 600,

    fn pad_shader(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
        const padded_len = (code.len + 3) & ~@as(usize, 3);
        var buf = try allocator.alloc(u8, padded_len);
        std.mem.copyForwards(u8, buf[0..code.len], code);
        if (padded_len > code.len) {
            for (buf[code.len..]) |*b| b.* = 0;
        }
        return buf;
    }

    fn create_upload_buffer(self: *Raytracing, size: usize, usage: u32, buffer_out: *?*nriframework.c.NriBuffer, memory_out: *?*nriframework.c.NriMemory) !void {
        var buffer_desc = nriframework.c.NriBufferDesc{
            .size = size,
            .usage = usage,
        };
        var buffer: ?*nriframework.c.NriBuffer = null;
        if (self.nri.core.CreateBuffer.?(self.device, &buffer_desc, &buffer) != nriframework.c.NriResult_SUCCESS or buffer == null)
            return error.NRICreateUploadBufferFailed;
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.nri.core.GetBufferMemoryDesc.?(buffer, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.nri.core.AllocateMemory.?(self.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateUploadBufferMemoryFailed;
        var binding = nriframework.c.NriBufferMemoryBindingDesc{
            .buffer = buffer,
            .memory = memory,
        };
        if (self.nri.core.BindBufferMemory.?(self.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindUploadBufferMemoryFailed;
        buffer_out.* = buffer;
        memory_out.* = memory;
    }

    pub fn create_raytracing_pipeline(self: *Raytracing, rgen_shader: []const u8, rmiss_shader: []const u8, rchit_shader: []const u8) !void {
        // Descriptor ranges: STORAGE_TEXTURE (output), ACCELERATION_STRUCTURE (TLAS)
        var descriptor_ranges = [2]nriframework.c.NriDescriptorRangeDesc{
            nriframework.c.NriDescriptorRangeDesc{
                .descriptorNum = 1,
                .descriptorType = nriframework.c.NriDescriptorType_STORAGE_TEXTURE,
                .baseRegisterIndex = 0,
                .shaderStages = nriframework.c.NriStageBits_RAYGEN_SHADER,
            },
            nriframework.c.NriDescriptorRangeDesc{
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
        if (self.nri.core.CreatePipelineLayout.?(self.device, &pipeline_layout_desc, &pipeline_layout) != nriframework.c.NriResult_SUCCESS or pipeline_layout == null)
            return error.NRICreatePipelineLayoutFailed;
        self.pipeline_layout = pipeline_layout;
        // Load shaders from memory, ensure codeSize is a multiple of 4 (Vulkan spec)
        const padded_rgen = try pad_shader(self.allocator, rgen_shader);
        defer if (padded_rgen.ptr != rgen_shader.ptr) self.allocator.free(padded_rgen);
        const padded_rmiss = try pad_shader(self.allocator, rmiss_shader);
        defer if (padded_rmiss.ptr != rmiss_shader.ptr) self.allocator.free(padded_rmiss);
        const padded_rchit = try pad_shader(self.allocator, rchit_shader);
        defer if (padded_rchit.ptr != rchit_shader.ptr) self.allocator.free(padded_rchit);
        var shaders = [3]nriframework.c.NriShaderDesc{
            nriframework.c.NriShaderDesc{
                .stage = nriframework.c.NriStageBits_RAYGEN_SHADER,
                .bytecode = padded_rgen.ptr,
                .size = padded_rgen.len,
            },
            nriframework.c.NriShaderDesc{
                .stage = nriframework.c.NriStageBits_MISS_SHADER,
                .bytecode = padded_rmiss.ptr,
                .size = padded_rmiss.len,
            },
            nriframework.c.NriShaderDesc{
                .stage = nriframework.c.NriStageBits_CLOSEST_HIT_SHADER,
                .bytecode = padded_rchit.ptr,
                .size = padded_rchit.len,
            },
        };
        var shader_library = nriframework.c.NriShaderLibraryDesc{
            .shaders = &shaders,
            .shaderNum = 3,
        };
        var shader_groups = [3]nriframework.c.NriShaderGroupDesc{
            nriframework.c.NriShaderGroupDesc{
                .type = nriframework.c.NriShaderGroupType_RAYGEN,
                .generalShaderIndex = 0,
                .closestHitShaderIndex = 0xFFFFFFFF,
                .anyHitShaderIndex = 0xFFFFFFFF,
                .intersectionShaderIndex = 0xFFFFFFFF,
            },
            nriframework.c.NriShaderGroupDesc{
                .type = nriframework.c.NriShaderGroupType_MISS,
                .generalShaderIndex = 1,
                .closestHitShaderIndex = 0xFFFFFFFF,
                .anyHitShaderIndex = 0xFFFFFFFF,
                .intersectionShaderIndex = 0xFFFFFFFF,
            },
            nriframework.c.NriShaderGroupDesc{
                .type = nriframework.c.NriShaderGroupType_HIT,
                .generalShaderIndex = 0xFFFFFFFF,
                .closestHitShaderIndex = 2,
                .anyHitShaderIndex = 0xFFFFFFFF,
                .intersectionShaderIndex = 0xFFFFFFFF,
            },
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
        if (self.nri.raytracing.CreateRayTracingPipeline.?(self.device, &pipeline_desc, &pipeline) != nriframework.c.NriResult_SUCCESS or pipeline == null)
            return error.NRICreateRayTracingPipelineFailed;
        self.pipeline = pipeline;
    }

    pub fn create_raytracing_output(self: *Raytracing) !void {
        // Output texture for raytracing result
        var output_desc = nriframework.c.NriTextureDesc{
            .type = nriframework.c.NriTextureType_TEXTURE_2D,
            .format = nriframework.c.NriFormat_RGBA8_UNORM,
            .width = 800, // TODO: dynamic size
            .height = 600,
            .depth = 1,
            .layerNum = 1,
            .mipNum = 1,
            .sampleNum = 1,
            .usage = nriframework.c.NriTextureUsageBits_SHADER_RESOURCE_STORAGE,
        };
        var output: ?*nriframework.c.NriTexture = null;
        if (self.nri.core.CreateTexture.?(self.device, &output_desc, &output) != nriframework.c.NriResult_SUCCESS or output == null)
            return error.NRICreateRayTracingOutputFailed;
        self.raytracing_output = output;
        // Allocate/bind memory
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.nri.core.GetTextureMemoryDesc.?(output, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.nri.core.AllocateMemory.?(self.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateRayTracingOutputMemoryFailed;
        var binding = nriframework.c.NriTextureMemoryBindingDesc{
            .texture = output,
            .memory = memory,
        };
        if (self.nri.core.BindTextureMemory.?(self.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindRayTracingOutputMemoryFailed;
        // Create view/descriptor
        var view_desc = nriframework.c.NriTexture2DViewDesc{
            .texture = output,
            .viewType = nriframework.c.NriTexture2DViewType_SHADER_RESOURCE_STORAGE_2D,
            .format = nriframework.c.NriFormat_RGBA8_UNORM,
        };
        var output_view: ?*nriframework.c.NriDescriptor = null;
        if (self.nri.core.CreateTexture2DView.?(&view_desc, &output_view) != nriframework.c.NriResult_SUCCESS or output_view == null)
            return error.NRICreateRayTracingOutputViewFailed;
        self.raytracing_output_view = output_view;
        // Bind output texture view to descriptor set (done in create_descriptor_set)
    }

    pub fn create_descriptor_set(self: *Raytracing) !void {
        // Pool
        var pool_desc = nriframework.c.NriDescriptorPoolDesc{
            .storageTextureMaxNum = 1,
            .accelerationStructureMaxNum = 1,
            .descriptorSetMaxNum = 1,
        };
        var pool: ?*nriframework.c.NriDescriptorPool = null;
        if (self.nri.core.CreateDescriptorPool.?(self.device, &pool_desc, &pool) != nriframework.c.NriResult_SUCCESS or pool == null)
            return error.NRICreateDescriptorPoolFailed;
        self.descriptor_pool = pool;
        // Set
        var set: ?*nriframework.c.NriDescriptorSet = null;
        if (self.nri.core.AllocateDescriptorSets.?(pool, self.pipeline_layout, 0, &set, 1, 0) != nriframework.c.NriResult_SUCCESS or set == null)
            return error.NRIAllocateDescriptorSetFailed;
        self.descriptor_set = set;
        // Bind output texture view
        var range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
            .descriptors = &self.raytracing_output_view,
            .descriptorNum = 1,
            .baseDescriptor = 0,
        };
        self.nri.core.UpdateDescriptorRanges.?(set, 0, 1, &range_update);
    }

    /// Initializes all raytracing resources, pipelines, and descriptor sets.
    pub fn init(
        self: *Raytracing,
        allocator: std.mem.Allocator,
        device: *nriframework.c.NriDevice,
        nri: nriframework.NRIInterface,
        queue: ?*nriframework.c.NriQueue,
        swapchain: *nriframework.c.NriSwapChain,
        frame_fence: ?*nriframework.c.NriFence,
        swapchain_textures: []types.SwapChainTexture,
        frames: ?[]types.QueuedFrame,
        rgen_spv: []const u8,
        rmiss_spv: []const u8,
        rchit_spv: []const u8,
    ) !void {
        self.allocator = allocator;
        self.device = device;
        self.nri = nri;
        self.queue = queue.?;
        self.swapchain = swapchain;
        self.frame_fence = frame_fence;
        self.swapchain_textures = swapchain_textures;
        self.frames = frames.?;
        try self.create_raytracing_pipeline(rgen_spv, rmiss_spv, rchit_spv);
        try self.create_raytracing_output();
        try self.create_descriptor_set();
        // Note: create_blas_tlas must be called with instances array by user after init
        try self.create_shader_table();
    }

    /// Creates BLAS and TLAS for the current scene, supporting multiple instances and dynamic updates.
    pub fn create_blas_tlas(self: *Raytracing, instances: []types.InstanceData) !void {
        // --- BLAS ---
        const vertex_data = [_]f32{ -0.5, -0.5, 0.0, 0.0, 0.5, 0.0, 0.5, -0.5, 0.0 };
        const index_data = [_]u16{ 0, 1, 2 };
        const vertex_data_size = @sizeOf(@TypeOf(vertex_data));
        const index_data_size = @sizeOf(@TypeOf(index_data));
        // Upload buffer for BLAS
        var upload_buffer: ?*nriframework.c.NriBuffer = null;
        var upload_memory: ?*nriframework.c.NriMemory = null;
        try self.create_upload_buffer(vertex_data_size + index_data_size, nriframework.c.NriBufferUsageBits_ACCELERATION_STRUCTURE_BUILD_INPUT, &upload_buffer, &upload_memory);
        // Map and copy data
        const data_ptr = self.nri.core.MapBuffer.?(upload_buffer, 0, vertex_data_size + index_data_size);
        const vertex_bytes = std.mem.sliceAsBytes(&vertex_data);
        const index_bytes = std.mem.sliceAsBytes(&index_data);
        const data_slice = @as([*]u8, @ptrCast(data_ptr))[0 .. vertex_data_size + index_data_size];
        std.mem.copyForwards(u8, data_slice[0..vertex_bytes.len], vertex_bytes);
        std.mem.copyForwards(u8, data_slice[vertex_bytes.len .. vertex_bytes.len + index_bytes.len], index_bytes);
        self.nri.core.UnmapBuffer.?(upload_buffer);
        // BLAS geometry
        var geometry = nriframework.c.NriBottomLevelGeometryDesc{
            .type = nriframework.c.NriAccelerationStructureType_BOTTOM_LEVEL,
            .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
            .triangles = nriframework.c.NriTriangles{
                .vertexBuffer = upload_buffer,
                .vertexOffset = 0,
                .vertexNum = 3,
                .vertexStride = 3 * @sizeOf(f32),
                .vertexFormat = nriframework.c.NriFormat_R32G32B32_SFLOAT,
                .indexBuffer = upload_buffer,
                .indexOffset = vertex_data_size,
                .indexNum = 3,
                .indexType = nriframework.c.NriIndexType_UINT16,
            },
        };
        var blas_desc = nriframework.c.NriAccelerationStructureDesc{
            .type = nriframework.c.NriAccelerationStructureType_BOTTOM_LEVEL,
            .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
            .instanceOrGeometryNum = 1,
            .geometries = &geometry,
        };
        var blas: ?*nriframework.c.NriAccelerationStructure = null;
        if (self.nri.raytracing.CreateAccelerationStructure.?(self.device, &blas_desc, &blas) != nriframework.c.NriResult_SUCCESS or blas == null)
            return error.NRICreateBLASFailed;
        self.blas = blas;
        // Allocate/bind memory
        var blas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.nri.raytracing.GetAccelerationStructureMemoryDesc.?(blas, nriframework.c.NriMemoryLocation_DEVICE, &blas_mem_desc);
        var blas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = blas_mem_desc.size,
            .type = blas_mem_desc.type,
        };
        var blas_memory: ?*nriframework.c.NriMemory = null;
        if (self.nri.core.AllocateMemory.?(self.device, &blas_alloc_desc, &blas_memory) != nriframework.c.NriResult_SUCCESS or blas_memory == null)
            return error.NRIAllocateBLASMemoryFailed;
        var blas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
            .accelerationStructure = blas,
            .memory = blas_memory,
        };
        if (self.nri.raytracing.BindAccelerationStructureMemory.?(self.device, &blas_binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindBLASMemoryFailed;
        // --- TLAS ---
        // Instance buffer (dynamic, multiple instances)
        const instance_count: u32 = @intCast(instances.len);
        const instance_size = @sizeOf(nriframework.c.NriInstanceDesc);
        var instance_buffer: ?*nriframework.c.NriBuffer = null;
        var instance_memory: ?*nriframework.c.NriMemory = null;
        try self.create_upload_buffer(instance_count * instance_size, nriframework.c.NriBufferUsageBits_ACCELERATION_STRUCTURE_BUILD_INPUT, &instance_buffer, &instance_memory);
        // Map and copy instances
        const inst_ptr = self.nri.core.MapBuffer.?(instance_buffer, 0, instance_count * instance_size);
        const inst_slice = @as([*]u8, @ptrCast(inst_ptr))[0 .. instance_count * instance_size];
        std.mem.copyForwards(u8, inst_slice, std.mem.sliceAsBytes(instances));
        self.nri.core.UnmapBuffer.?(instance_buffer);
        // TLAS desc
        var tlas_desc = nriframework.c.NriAccelerationStructureDesc{
            .type = nriframework.c.NriAccelerationStructureType_TOP_LEVEL,
            .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
            .instanceOrGeometryNum = instance_count,
            .instances = instance_buffer,
        };
        var tlas: ?*nriframework.c.NriAccelerationStructure = null;
        if (self.nri.raytracing.CreateAccelerationStructure.?(self.device, &tlas_desc, &tlas) != nriframework.c.NriResult_SUCCESS or tlas == null)
            return error.NRICreateTLASFailed;
        self.tlas = tlas;
        // Allocate/bind memory
        var tlas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.nri.raytracing.GetAccelerationStructureMemoryDesc.?(tlas, nriframework.c.NriMemoryLocation_DEVICE, &tlas_mem_desc);
        var tlas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = tlas_mem_desc.size,
            .type = tlas_mem_desc.type,
        };
        var tlas_memory: ?*nriframework.c.NriMemory = null;
        if (self.nri.core.AllocateMemory.?(self.device, &tlas_alloc_desc, &tlas_memory) != nriframework.c.NriResult_SUCCESS or tlas_memory == null)
            return error.NRIAllocateTLASMemoryFailed;
        var tlas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
            .accelerationStructure = tlas,
            .memory = tlas_memory,
        };
        if (self.nri.raytracing.BindAccelerationStructureMemory.?(self.device, &tlas_binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindTLASMemoryFailed;
        // Create TLAS descriptor for binding
        var tlas_desc_view: ?*nriframework.c.NriDescriptor = null;
        if (self.nri.core.CreateAccelerationStructureView.?(tlas, &tlas_desc_view) != nriframework.c.NriResult_SUCCESS or tlas_desc_view == null)
            return error.NRICreateTLASDescriptorFailed;
        self.tlas_descriptor = tlas_desc_view;
        // Bind TLAS to descriptor set (register 1)
        var tlas_range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
            .descriptors = &self.tlas_descriptor,
            .descriptorNum = 1,
            .baseRegisterIndex = 1,
        };
        self.nri.core.UpdateDescriptorRanges.?(self.descriptor_set, 0, 1, &tlas_range_update);
    }

    pub fn create_shader_table(self: *Raytracing) !void {
        // Get identifier size from device
        const device_desc = self.nri.core.GetDeviceDesc.?(self.device);
        const identifier_size: usize = device_desc.*.shaderStage.rayTracing.shaderGroupIdentifierSize;
        // Offsets for raygen, miss, hit
        self.shader_table_raygen_offset = 0;
        self.shader_table_miss_offset = identifier_size;
        self.shader_table_hit_offset = 2 * identifier_size;
        self.shader_table_stride = identifier_size;
        const total_size = 3 * identifier_size;
        // Create shader table buffer
        var shader_table_desc = nriframework.c.NriBufferDesc{
            .size = total_size,
            .usage = nriframework.c.NriBufferUsageBits_SHADER_BINDING_TABLE,
        };
        var shader_table: ?*nriframework.c.NriBuffer = null;
        if (self.nri.core.CreateBuffer.?(self.device, &shader_table_desc, &shader_table) != nriframework.c.NriResult_SUCCESS or shader_table == null)
            return error.NRICreateShaderTableFailed;
        self.shader_table = shader_table;
        // Allocate/bind memory
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.nri.core.GetBufferMemoryDesc.?(shader_table, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.nri.core.AllocateMemory.?(self.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateShaderTableMemoryFailed;
        var binding = nriframework.c.NriBufferMemoryBindingDesc{
            .buffer = shader_table,
            .memory = memory,
        };
        if (self.nri.core.BindBufferMemory.?(self.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindShaderTableMemoryFailed;
        self.shader_table_memory = memory;
        // Write shader group identifiers
        if (self.nri.raytracing.WriteShaderGroupIdentifiers) |WriteShaderGroupIdentifiers| {
            _ = WriteShaderGroupIdentifiers(self.pipeline, 0, 3, shader_table);
        }
    }

    pub fn record_and_submit(self: *Raytracing, frame_index: u32, image_index: u32) !void {
        var frame = &self.frames[frame_index % self.frames.len];
        self.nri.core.ResetCommandAllocator.?(frame.command_allocator);
        if (self.nri.core.BeginCommandBuffer.?(frame.command_buffer, self.descriptor_pool) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBeginCommandBufferFailed;
        // Barriers: swapchain to COPY_DEST, raytracing output to GENERAL
        const swapchain_tex = &self.swapchain_textures[image_index];
        const barrier_swapchain_to_copy_dst = nriframework.c.NriTextureBarrierDesc{
            .texture = @ptrCast(swapchain_tex.texture),
            .before = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_UNKNOWN,
            },
            .after = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_COPY_DESTINATION,
                .layout = nriframework.c.NriLayout_COPY_DESTINATION,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc1 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_swapchain_to_copy_dst,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc1);
        // Raytracing output barrier
        const rt_output_before = if (frame_index == 0)
            nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_UNKNOWN,
            }
        else
            nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_COPY_SOURCE,
                .layout = nriframework.c.NriLayout_COPY_SOURCE,
            };
        const barrier_rt_output_to_general = nriframework.c.NriTextureBarrierDesc{
            .texture = self.raytracing_output,
            .before = rt_output_before,
            .after = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_SHADER_RESOURCE_STORAGE,
                .layout = nriframework.c.NriLayout_SHADER_RESOURCE_STORAGE,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc2 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_rt_output_to_general,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc2);
        // Bind pipeline, layout, descriptor set
        self.nri.core.CmdSetPipelineLayout.?(frame.command_buffer, self.pipeline_layout);
        self.nri.core.CmdSetPipeline.?(frame.command_buffer, self.pipeline);
        self.nri.core.CmdSetDescriptorSet.?(frame.command_buffer, 0, self.descriptor_set, null);
        // Dispatch rays
        const identifier_size = self.shader_table_stride;
        var dispatch_desc = nriframework.c.NriDispatchRaysDesc{
            .raygenShader = .{
                .buffer = self.shader_table,
                .offset = self.shader_table_raygen_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .missShaders = .{
                .buffer = self.shader_table,
                .offset = self.shader_table_miss_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .hitShaderGroups = .{
                .buffer = self.shader_table,
                .offset = self.shader_table_hit_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .x = 800, // TODO: dynamic size
            .y = 600,
            .z = 1,
        };
        self.nri.raytracing.CmdDispatchRays.?(frame.command_buffer, &dispatch_desc);
        // Raytracing output to COPY_SRC
        const barrier_rt_output_to_copy_src = nriframework.c.NriTextureBarrierDesc{
            .texture = self.raytracing_output,
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
        var barrier_desc3 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_rt_output_to_copy_src,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc3);
        // Copy raytracing output to swapchain
        self.nri.core.CmdCopyTexture.?(frame.command_buffer, @ptrCast(swapchain_tex.texture), null, self.raytracing_output, null);
        // Swapchain to PRESENT
        const barrier_swapchain_to_present = nriframework.c.NriTextureBarrierDesc{
            .texture = @ptrCast(swapchain_tex.texture),
            .before = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_COPY_DESTINATION,
                .layout = nriframework.c.NriLayout_COPY_DESTINATION,
            },
            .after = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_PRESENT,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc4 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_swapchain_to_present,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc4);
        if (self.nri.core.EndCommandBuffer.?(frame.command_buffer) != nriframework.c.NriResult_SUCCESS)
            return error.NRIEndCommandBufferFailed;
        // Submit
        var wait_fence_descs = [_]nriframework.c.NriFenceSubmitDesc{
            .{ .fence = @ptrCast(swapchain_tex.acquireSemaphore), .stages = nriframework.c.NriStageBits_ALL },
        };
        var signal_fence_descs = [_]nriframework.c.NriFenceSubmitDesc{
            .{ .fence = @ptrCast(swapchain_tex.releaseSemaphore) },
            .{ .fence = self.frame_fence, .value = 1 + frame_index },
        };
        var submit_desc = nriframework.c.NriQueueSubmitDesc{
            .commandBuffers = &frame.command_buffer,
            .commandBufferNum = 1,
            .waitFences = &wait_fence_descs,
            .waitFenceNum = 1,
            .signalFences = &signal_fence_descs,
            .signalFenceNum = 2,
        };
        self.nri.core.QueueSubmit.?(self.queue, &submit_desc);
    }

    pub fn update_dispatch_dimensions(self: *Raytracing, width: u32, height: u32) void {
        // Update any internal state needed for dispatch (e.g., output texture size, shader table, etc.)
        // If output texture or descriptor sets depend on size, recreate them here
        self.output_width = width;
        self.output_height = height;
        // If you need to recreate output/descriptor, do so here or call the relevant methods
        // try self.create_raytracing_output();
        // try self.create_descriptor_set();
    }
};
