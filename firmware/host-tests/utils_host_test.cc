#include "lan_mic_app_internal.h"

#include <cassert>
#include <iostream>
#include <string>
#include <vector>

namespace {

void ExpectLines(const std::vector<std::string>& lines,
                 std::initializer_list<const char*> expected) {
    assert(lines.size() == expected.size());
    size_t i = 0;
    for (const char* line : expected) {
        assert(lines[i] == line);
        ++i;
    }
}

void TestAsciiWrap() {
    const auto lines = WrapUtf8Lines("hello world", 5);
    ExpectLines(lines, {"hello", " worl", "d"});
}

void TestCjkWrap() {
    const auto lines = WrapUtf8Lines("你好世界", 2);
    ExpectLines(lines, {"你好", "世界"});
}

void TestNewlineFlush() {
    const auto lines = WrapUtf8Lines("a\nbc", 10);
    ExpectLines(lines, {"a", "bc"});
}

void TestMaxLines() {
    const auto lines = WrapUtf8Lines("one two three four", 4, 2);
    ExpectLines(lines, {"one ", "two "});
}

void TestFormatTodoRightTimeText() {
    assert(FormatTodoRightTimeText("2026-07-03") == "07/03");
    assert(FormatTodoRightTimeText("2026-07-03T08:30:00Z") == "07/03");
    assert(FormatTodoRightTimeText("bad") == "");
}

} // namespace

int main() {
    TestAsciiWrap();
    TestCjkWrap();
    TestNewlineFlush();
    TestMaxLines();
    TestFormatTodoRightTimeText();
    std::cout << "firmware host tests passed\n";
    return 0;
}
