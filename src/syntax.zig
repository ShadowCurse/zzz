extensions: []const []const u8,
keywords: []const []const u8,
singleline_comment_start: []const u8,
multiline_comment_start: []const u8,
multiline_comment_end: []const u8,
flags: u32,

const Self = @This();

pub const HL_NORMAL = 0;
pub const HL_NONPRINT = 1;
pub const HL_COMMENT = 2;
pub const HL_MLCOMMENT = 3;
pub const HL_KEYWORD1 = 4;
pub const HL_KEYWORD2 = 5;
pub const HL_STRING = 6;
pub const HL_NUMBER = 7;
pub const HL_MATCH = 8;
pub const HL_HIGHLIGHT_STRINGS = (1 << 0);
pub const HL_HIGHLIGHT_NUMBERS = (1 << 1);

// Here we define an array of syntax highlights by extensions, keywords, comments delimiters and flags.
pub const SYNTAX_ARRAY = [_]Self{
// C / C++
Self{
    .extensions = &HL_extensions,
    .keywords = &HL_keywords,
    .singleline_comment_start = "//",
    .multiline_comment_start = "/*",
    .multiline_comment_end = "*/",
    .flags = HL_HIGHLIGHT_STRINGS | HL_HIGHLIGHT_NUMBERS,
}};

// Maps syntax highlight token types to terminal colors.
pub fn syntaxToColor(hl: i32) i32 {
    switch (hl) {
        HL_COMMENT, HL_MLCOMMENT => return 36, // cyan
        HL_KEYWORD1 => return 33, // yellow
        HL_KEYWORD2 => return 32, // green
        HL_STRING => return 35, // magenta
        HL_NUMBER => return 31, // red
        HL_MATCH => return 34, // blu
        else => return 37, // white
    }
}

const HL_extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
const HL_keywords = [_][]const u8{
    "auto",          "break",       "case",     "continue",  "default",      "do",        "else",   "enum",
    "extern",        "for",         "goto",     "if",        "register",     "return",    "sizeof", "static",
    "struct",        "switch",      "typedef",  "union",     "volatile",     "while",     "NULL",   "alignas",
    "alignof",       "and",         "and_eq",   "asm",       "bitand",       "bitor",     "class",  "compl",
    "constexpr",     "const_cast",  "deltype",  "delete",    "dynamic_cast", "explicit",  "export", "false",
    "friend",        "inline",      "mutable",  "namespace", "new",          "noexcept",  "not",    "not_eq",
    "nullptr",       "operator",    "or",       "or_eq",     "private",      "protected", "public", "reinterpret_cast",
    "static_assert", "static_cast", "template", "this",      "thread_local", "throw",     "true",   "try",
    "typeid",        "typename",    "virtual",  "xor",       "xor_eq",       "int",       "long",   "double",
    "float",         "char",        "unsigned", "signed",    "void",         "short",     "const",  "bool",
};
