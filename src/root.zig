// 导出C绑定
pub const c = @import("c.zig").c;
pub const errors = @import("errors.zig");

// 导出高级API
pub const rknpu2 = @import("Rknn.zig");

// re-export 主要的类型和常量
pub usingnamespace errors;
pub usingnamespace rknpu2;
