extensions: []const []const u8,
keywords: []const []const u8,
singleline_comment_start: []const u8,
multiline_comment_start: []const u8,
multiline_comment_end: []const u8,

const Self = @This();

pub const HighlightType = enum {
    HL_NORMAL,
    HL_NONPRINT,
    HL_COMMENT,
    HL_KEYWORD1,
    HL_KEYWORD2,
    HL_STRING,
    HL_NUMBER,
    HL_MATCH,
    HL_HIGHLIGHT_STRINGS,
    HL_HIGHLIGHT_NUMBERS,
};

// Here we define an array of syntax highlights by extensions, keywords, comments delimiters and flags.
pub const SYNTAX_ARRAY = [_]Self{
// C / C++
Self{
    .extensions = &HL_extensions,
    .keywords = &HL_keywords,
    .singleline_comment_start = "//",
    .multiline_comment_start = "/*",
    .multiline_comment_end = "*/",
}};

// TODO make configurable maybe
// Maps syntax highlight token types to terminal colors.
pub fn highlightToColor(hl: HighlightType) u8 {
    switch (hl) {
        .HL_COMMENT => return 36, // cyan
        .HL_KEYWORD1 => return 33, // yellow
        .HL_KEYWORD2 => return 32, // green
        .HL_STRING => return 35, // magenta
        .HL_NUMBER => return 31, // red
        .HL_MATCH => return 34, // blue
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
