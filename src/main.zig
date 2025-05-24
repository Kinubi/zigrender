const std = @import("std");

const nri = @cImport({
    @cInclude("stddef.h");
    @cInclude("NRI.h");
    @cInclude("Extensions/NRIDeviceCreation.h");
    @cInclude("Extensions/NRIHelper.h");
    @cInclude("Extensions/NRIResourceAllocator.h");
});

pub fn main() !void {
    var device: ?*nri.NriDevice = null;
    var adapterDescs: [2]nri.NriAdapterDesc = .{ .{}, .{} };
    var adapterDescNum: u32 = 2;
    var result: nri.NriResult = nri.nriEnumerateAdapters(@ptrCast(&adapterDescs[0]), @ptrCast(&adapterDescNum));
    std.debug.print("This is the first result: {any}", .{result});
    result = nri.nriCreateDevice(&nri.NriDeviceCreationDesc{ .graphicsAPI = nri.NriGraphicsAPI_VK, .enableGraphicsAPIValidation = true, .enableNRIValidation = true, .adapterDesc = @ptrCast(&adapterDescs[0]) }, @ptrCast(&device));
    std.debug.print("This is the second result: {any}", .{result});
    std.debug.print("This is the Name: {s}", .{adapterDescs[0].name});
}
