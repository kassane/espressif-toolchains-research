const Blob = extern struct { data: [24]u8 };
extern fn ext_blob_sum(Blob) callconv(.c) u32;
export fn caller(b: Blob) u32 { return ext_blob_sum(b); }
