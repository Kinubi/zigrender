const std = @import("std");
const nriframework = @import("nriframework.zig");
const types = @import("types/index.zig");
const swapchain_mod = @import("swapchain.zig");

/// Raytracing class encapsulating all raytracing resource creation, per-frame logic, and dynamic scene support.
pub const Raytracing = struct {
    allocator: std.mem.Allocator,
    swapchain: *swapchain_mod.Swapchain, // Use the abstracted Swapchain
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
        if (self.swapchain.nri.core.CreateBuffer.?(self.swapchain.device, &buffer_desc, &buffer) != nriframework.c.NriResult_SUCCESS or buffer == null)
            return error.NRICreateUploadBufferFailed;
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.swapchain.nri.core.GetBufferMemoryDesc.?(buffer, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.swapchain.nri.core.AllocateMemory.?(self.swapchain.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateUploadBufferMemoryFailed;
        var binding = nriframework.c.NriBufferMemoryBindingDesc{
            .buffer = buffer,
            .memory = memory,
        };
        if (self.swapchain.nri.core.BindBufferMemory.?(self.swapchain.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
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
        if (self.swapchain.nri.core.CreatePipelineLayout.?(self.swapchain.device, &pipeline_layout_desc, &pipeline_layout) != nriframework.c.NriResult_SUCCESS or pipeline_layout == null)
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
            .{ .shaderIndices = .{ 3, 0, 0 } },
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
        if (self.swapchain.nri.raytracing.CreateRayTracingPipeline.?(self.swapchain.device, &pipeline_desc, &pipeline) != nriframework.c.NriResult_SUCCESS or pipeline == null)
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
        if (self.swapchain.nri.core.CreateTexture.?(self.swapchain.device, &output_desc, &output) != nriframework.c.NriResult_SUCCESS or output == null)
            return error.NRICreateRayTracingOutputFailed;
        self.raytracing_output = output;
        // Allocate/bind memory
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.swapchain.nri.core.GetTextureMemoryDesc.?(output, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.swapchain.nri.core.AllocateMemory.?(self.swapchain.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateRayTracingOutputMemoryFailed;
        var binding = nriframework.c.NriTextureMemoryBindingDesc{
            .texture = output,
            .memory = memory,
        };
        if (self.swapchain.nri.core.BindTextureMemory.?(self.swapchain.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindRayTracingOutputMemoryFailed;
        // Create view/descriptor
        var view_desc = nriframework.c.NriTexture2DViewDesc{
            .texture = output,
            .viewType = nriframework.c.NriTexture2DViewType_SHADER_RESOURCE_STORAGE_2D,
            .format = nriframework.c.NriFormat_RGBA8_UNORM,
        };
        var output_view: ?*nriframework.c.NriDescriptor = null;
        if (self.swapchain.nri.core.CreateTexture2DView.?(&view_desc, &output_view) != nriframework.c.NriResult_SUCCESS or output_view == null)
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
        if (self.swapchain.nri.core.CreateDescriptorPool.?(self.swapchain.device, &pool_desc, &pool) != nriframework.c.NriResult_SUCCESS or pool == null)
            return error.NRICreateDescriptorPoolFailed;
        self.descriptor_pool = pool;
        // Set
        var set: ?*nriframework.c.NriDescriptorSet = null;
        if (self.swapchain.nri.core.AllocateDescriptorSets.?(pool, self.pipeline_layout, 0, &set, 1, 0) != nriframework.c.NriResult_SUCCESS or set == null)
            return error.NRIAllocateDescriptorSetFailed;
        self.descriptor_set = set;
        // Bind output texture view
        var range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
            .descriptors = &self.raytracing_output_view,
            .descriptorNum = 1,
            .baseDescriptor = 0,
        };
        self.swapchain.nri.core.UpdateDescriptorRanges.?(set, 0, 1, &range_update);
    }

    /// Initializes all raytracing resources, pipelines, and descriptor sets.
    pub fn init(
        allocator: std.mem.Allocator,
        swapchain: *swapchain_mod.Swapchain, // Use the abstracted Swapchain
        frame_fence: ?*nriframework.c.NriFence,
        swapchain_textures: []types.SwapChainTexture,
        frames: ?[]types.QueuedFrame,
        rgen_spv: []const u8,
        rmiss_spv: []const u8,
        rchit_spv: []const u8,
    ) !Raytracing {
        var self = Raytracing{
            .allocator = allocator,
            .swapchain = swapchain,
            .frame_fence = frame_fence,
            .swapchain_textures = swapchain_textures,
            .frames = frames.?,
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .raytracing_output = null,
            .raytracing_output_view = null,
            .blas = null,
            .tlas = null,
            .tlas_descriptor = null,
            .shader_table = null,
            .shader_table_memory = null,
            .shader_table_raygen_offset = 0,
            .shader_table_miss_offset = 0,
            .shader_table_hit_offset = 0,
            .shader_table_stride = 0,
            .output_width = 800,
            .output_height = 600,
        };
        try self.create_raytracing_pipeline(rgen_spv, rmiss_spv, rchit_spv);
        try self.create_raytracing_output();
        try self.create_descriptor_set();
        // Note: create_blas_tlas must be called with instances array by user after init
        try self.create_shader_table();
        try self.init_command_buffers();
        return self;
    }
    pub fn init_command_buffers(self: *Raytracing) !void {
        for (self.frames) |*frame| {
            // Create command allocator
            var command_allocator: ?*nriframework.c.NriCommandAllocator = null;
            if (self.swapchain.nri.core.CreateCommandAllocator.?(self.swapchain.graphics_queue, &command_allocator) != nriframework.c.NriResult_SUCCESS or command_allocator == null)
                return error.NRICreateCommandAllocatorFailed;
            frame.command_allocator = command_allocator;

            // Create command buffer
            var command_buffer: ?*nriframework.c.NriCommandBuffer = null;
            if (self.swapchain.nri.core.CreateCommandBuffer.?(command_allocator, &command_buffer) != nriframework.c.NriResult_SUCCESS or command_buffer == null)
                return error.NRICreateCommandBufferFailed;
            frame.command_buffer = command_buffer;
        }
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
        const data_ptr = self.swapchain.nri.core.MapBuffer.?(upload_buffer, 0, vertex_data_size + index_data_size);
        const vertex_bytes = std.mem.sliceAsBytes(&vertex_data);
        const index_bytes = std.mem.sliceAsBytes(&index_data);
        const data_slice = @as([*]u8, @ptrCast(data_ptr))[0 .. vertex_data_size + index_data_size];
        std.mem.copyForwards(u8, data_slice[0..vertex_bytes.len], vertex_bytes);
        std.mem.copyForwards(u8, data_slice[vertex_bytes.len .. vertex_bytes.len + index_bytes.len], index_bytes);
        self.swapchain.nri.core.UnmapBuffer.?(upload_buffer);
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
        if (self.swapchain.nri.raytracing.CreateAccelerationStructure.?(self.swapchain.device, &blas_desc, &blas) != nriframework.c.NriResult_SUCCESS or blas == null)
            return error.NRICreateBLASFailed;
        self.blas = blas;
        // Allocate/bind memory
        var blas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.swapchain.nri.raytracing.GetAccelerationStructureMemoryDesc.?(blas, nriframework.c.NriMemoryLocation_DEVICE, &blas_mem_desc);
        var blas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = blas_mem_desc.size,
            .type = blas_mem_desc.type,
        };
        var blas_memory: ?*nriframework.c.NriMemory = null;
        if (self.swapchain.nri.core.AllocateMemory.?(self.swapchain.device, &blas_alloc_desc, &blas_memory) != nriframework.c.NriResult_SUCCESS or blas_memory == null)
            return error.NRIAllocateBLASMemoryFailed;
        var blas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
            .accelerationStructure = blas,
            .memory = blas_memory,
        };
        if (self.swapchain.nri.raytracing.BindAccelerationStructureMemory.?(self.swapchain.device, &blas_binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindBLASMemoryFailed;
        // --- TLAS ---
        // Instance buffer (dynamic, multiple instances)
        const instance_count: u32 = @intCast(instances.len);
        const instance_size = @sizeOf(nriframework.c.NriInstanceDesc);
        var instance_buffer: ?*nriframework.c.NriBuffer = null;
        var instance_memory: ?*nriframework.c.NriMemory = null;
        try self.create_upload_buffer(instance_count * instance_size, nriframework.c.NriBufferUsageBits_ACCELERATION_STRUCTURE_BUILD_INPUT, &instance_buffer, &instance_memory);
        // Map and copy instances
        const inst_ptr = self.swapchain.nri.core.MapBuffer.?(instance_buffer, 0, instance_count * instance_size);
        const inst_slice = @as([*]u8, @ptrCast(inst_ptr))[0 .. instance_count * instance_size];
        std.mem.copyForwards(u8, inst_slice, std.mem.sliceAsBytes(instances));
        self.swapchain.nri.core.UnmapBuffer.?(instance_buffer);
        // TLAS desc
        var tlas_desc = nriframework.c.NriAccelerationStructureDesc{
            .type = nriframework.c.NriAccelerationStructureType_TOP_LEVEL,
            .flags = nriframework.c.NriAccelerationStructureBits_PREFER_FAST_TRACE,
            .instanceOrGeometryNum = instance_count,
            .instances = instance_buffer,
        };
        var tlas: ?*nriframework.c.NriAccelerationStructure = null;
        if (self.swapchain.nri.raytracing.CreateAccelerationStructure.?(self.swapchain.device, &tlas_desc, &tlas) != nriframework.c.NriResult_SUCCESS or tlas == null)
            return error.NRICreateTLASFailed;
        self.tlas = tlas;
        // Allocate/bind memory
        var tlas_mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.swapchain.nri.raytracing.GetAccelerationStructureMemoryDesc.?(tlas, nriframework.c.NriMemoryLocation_DEVICE, &tlas_mem_desc);
        var tlas_alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = tlas_mem_desc.size,
            .type = tlas_mem_desc.type,
        };
        var tlas_memory: ?*nriframework.c.NriMemory = null;
        if (self.swapchain.nri.core.AllocateMemory.?(self.swapchain.device, &tlas_alloc_desc, &tlas_memory) != nriframework.c.NriResult_SUCCESS or tlas_memory == null)
            return error.NRIAllocateTLASMemoryFailed;
        var tlas_binding = nriframework.c.NriAccelerationStructureMemoryBindingDesc{
            .accelerationStructure = tlas,
            .memory = tlas_memory,
        };
        if (self.swapchain.nri.raytracing.BindAccelerationStructureMemory.?(self.swapchain.device, &tlas_binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindTLASMemoryFailed;
        // Create TLAS descriptor for binding
        var tlas_desc_view: ?*nriframework.c.NriDescriptor = null;
        if (self.swapchain.nri.core.CreateAccelerationStructureView.?(tlas, &tlas_desc_view) != nriframework.c.NriResult_SUCCESS or tlas_desc_view == null)
            return error.NRICreateTLASDescriptorFailed;
        self.tlas_descriptor = tlas_desc_view;
        // Bind TLAS to descriptor set (register 1)
        var tlas_range_update = nriframework.c.NriDescriptorRangeUpdateDesc{
            .descriptors = &self.tlas_descriptor,
            .descriptorNum = 1,
            .baseRegisterIndex = 1,
        };
        self.swapchain.nri.core.UpdateDescriptorRanges.?(self.descriptor_set, 0, 1, &tlas_range_update);
    }

    pub fn create_shader_table(self: *Raytracing) !void {
        // Get identifier size from device
        const device_desc = self.swapchain.nri.core.GetDeviceDesc.?(self.swapchain.device);
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
        if (self.swapchain.nri.core.CreateBuffer.?(self.swapchain.device, &shader_table_desc, &shader_table) != nriframework.c.NriResult_SUCCESS or shader_table == null)
            return error.NRICreateShaderTableFailed;
        self.shader_table = shader_table;
        // Allocate/bind memory
        var mem_desc: nriframework.c.NriMemoryDesc = undefined;
        self.swapchain.nri.core.GetBufferMemoryDesc.?(shader_table, nriframework.c.NriMemoryLocation_DEVICE, &mem_desc);
        var alloc_desc = nriframework.c.NriAllocateMemoryDesc{
            .size = mem_desc.size,
            .type = mem_desc.type,
        };
        var memory: ?*nriframework.c.NriMemory = null;
        if (self.swapchain.nri.core.AllocateMemory.?(self.swapchain.device, &alloc_desc, &memory) != nriframework.c.NriResult_SUCCESS or memory == null)
            return error.NRIAllocateShaderTableMemoryFailed;
        var binding = nriframework.c.NriBufferMemoryBindingDesc{
            .buffer = shader_table,
            .memory = memory,
        };
        if (self.swapchain.nri.core.BindBufferMemory.?(self.swapchain.device, &binding, 1) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBindShaderTableMemoryFailed;
        self.shader_table_memory = memory;
        // Write shader group identifiers
        if (self.swapchain.nri.raytracing.WriteShaderGroupIdentifiers) |WriteShaderGroupIdentifiers| {
            _ = WriteShaderGroupIdentifiers(self.pipeline, 0, 3, shader_table);
        }
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
