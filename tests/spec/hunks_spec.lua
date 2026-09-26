local hunks = require("picked.git.hunks")

describe("hunk engine", function()
  describe("parsing", function()
    it("parses a single hunk", function()
      local diff = table.concat({
        "diff --git a/f.lua b/f.lua",
        "index 111..222 100644",
        "--- a/f.lua",
        "+++ b/f.lua",
        "@@ -20,7 +20,8 @@ local function hello()",
        " context one",
        "-removed",
        "+added one",
        "+added two",
        " context two",
      }, "\n")

      local parsed = hunks.parse(diff)
      assert.equals(1, #parsed)
      local hunk = parsed[1]
      assert.equals(20, hunk.old_start)
      assert.equals(7, hunk.old_count)
      assert.equals(20, hunk.new_start)
      assert.equals(8, hunk.new_count)
      assert.equals("local function hello()", hunk.heading)
      assert.equals("change", hunk.type)
      assert.equals(5, #hunk.lines)
    end)

    it("treats an omitted count as one", function()
      local parsed = hunks.parse("@@ -5 +5 @@\n-a\n+b\n")
      assert.equals(1, parsed[1].old_count)
      assert.equals(1, parsed[1].new_count)
    end)

    it("classifies pure insertions and deletions", function()
      local added = hunks.parse("@@ -0,0 +1,2 @@\n+one\n+two\n")[1]
      assert.equals("add", added.type)
      local removed = hunks.parse("@@ -1,2 +0,0 @@\n-one\n-two\n")[1]
      assert.equals("delete", removed.type)
    end)

    it("parses several hunks and numbers them", function()
      local parsed = hunks.parse(table.concat({
        "@@ -1,2 +1,2 @@",
        " a",
        "-b",
        "+B",
        "@@ -10,2 +10,3 @@",
        " x",
        "+y",
        " z",
      }, "\n"))
      assert.equals(2, #parsed)
      assert.equals(1, parsed[1].index)
      assert.equals(2, parsed[2].index)
      assert.equals(10, parsed[2].old_start)
    end)

    it("keeps no-newline markers with their hunk", function()
      local parsed = hunks.parse("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n")
      assert.equals(3, #parsed[1].lines)
      assert.equals("\\ No newline at end of file", parsed[1].lines[2])
    end)

    it("stops a hunk at the next file header", function()
      local parsed = hunks.parse(table.concat({
        "@@ -1 +1 @@",
        "-a",
        "+b",
        "diff --git a/other b/other",
        "--- a/other",
        "+++ b/other",
        "@@ -1 +1 @@",
        "-c",
        "+d",
      }, "\n"))
      assert.equals(2, #parsed)
      assert.equals(2, #parsed[1].lines)
      assert.equals(2, #parsed[2].lines)
    end)

    it("returns nothing for empty or header-only input", function()
      assert.equals(0, #hunks.parse(""))
      assert.equals(0, #hunks.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n"))
    end)
  end)

  describe("computation with vim.diff", function()
    it("produces hunks with context", function()
      local old_text = "one\ntwo\nthree\nfour\nfive\n"
      local new_text = "one\ntwo\nTHREE\nfour\nfive\n"
      local parsed = hunks.compute(old_text, new_text, { context = 1 })
      assert.equals(1, #parsed)
      local hunk = parsed[1]
      assert.equals("change", hunk.type)
      -- one context line either side of the change
      assert.same({ " two", "-three", "+THREE", " four" }, hunk.lines)
    end)

    it("reports no hunks for identical text", function()
      assert.equals(0, #hunks.compute("same\n", "same\n"))
    end)

    it("handles a file with no trailing newline", function()
      local parsed = hunks.compute("a\nb", "a\nB")
      assert.is_true(#parsed >= 1)
      local _, removed = hunks.counts(parsed[1])
      assert.is_true(removed >= 1)
    end)
  end)

  describe("recounting", function()
    it("derives counts from the body", function()
      local hunk = hunks.parse("@@ -1,99 +1,99 @@\n a\n-b\n+c\n+d\n e\n")[1]
      local old_count, new_count = hunks.recount(hunk)
      assert.equals(3, old_count) -- a, b, e
      assert.equals(4, new_count) -- a, c, d, e
    end)

    it("ignores no-newline markers when counting", function()
      local hunk = hunks.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n")[1]
      local old_count, new_count = hunks.recount(hunk)
      assert.equals(1, old_count)
      assert.equals(1, new_count)
    end)
  end)

  describe("line ranges", function()
    it("maps a change hunk to its buffer lines", function()
      local hunk = hunks.parse("@@ -10,3 +10,4 @@\n ctx\n-old\n+new1\n+new2\n ctx\n")[1]
      local first, last = hunks.new_range(hunk)
      assert.equals(10, first)
      assert.equals(13, last)
    end)

    it("anchors a pure deletion to a zero-width range", function()
      local hunk = { old_start = 10, old_count = 2, new_start = 9, new_count = 0, lines = {}, type = "delete" }
      local first, last = hunks.new_range(hunk)
      assert.equals(9, first)
      assert.equals(9, last)
    end)

    it("finds the hunk under a line", function()
      local list = hunks.parse(table.concat({
        "@@ -1,2 +1,3 @@",
        " a",
        "+b",
        " c",
        "@@ -20,2 +21,3 @@",
        " x",
        "+y",
        " z",
      }, "\n"))
      local hunk, index = hunks.at_line(list, 2)
      assert.equals(1, index)
      assert.equals(1, hunk.new_start)

      local second, second_index = hunks.at_line(list, 22)
      assert.equals(2, second_index)
      assert.equals(21, second.new_start)

      assert.is_nil(hunks.at_line(list, 10))
    end)
  end)

  describe("partial selection", function()
    local function hunk_with(body)
      return hunks.parse("@@ -10,4 +10,4 @@\n" .. body)[1]
    end

    it("keeps only the selected addition", function()
      local hunk = hunk_with(" ctx\n+one\n+two\n ctx2\n")
      -- body indices: 1=ctx 2=+one 3=+two 4=ctx2
      local partial = hunks.select_body(hunk, { [2] = true })
      assert.same({ " ctx", "+one", " ctx2" }, partial.lines)
      assert.equals(2, partial.old_count)
      assert.equals(3, partial.new_count)
    end)

    it("turns an unselected deletion into context", function()
      local hunk = hunk_with(" ctx\n-one\n-two\n ctx2\n")
      local partial = hunks.select_body(hunk, { [2] = true })
      assert.same({ " ctx", "-one", " two", " ctx2" }, partial.lines)
      assert.equals(4, partial.old_count)
      assert.equals(3, partial.new_count)
    end)

    it("returns nil when nothing is selected", function()
      local hunk = hunk_with(" ctx\n+one\n ctx2\n")
      assert.is_nil(hunks.select_body(hunk, {}))
    end)

    it("selects additions by their buffer line number", function()
      local hunk = hunks.parse("@@ -10,2 +10,4 @@\n ctx\n+a\n+b\n ctx2\n")[1]
      -- new side: 10=ctx 11=a 12=b 13=ctx2
      local partial = hunks.select_range(hunk, 12, 12)
      assert.same({ " ctx", "+b", " ctx2" }, partial.lines)
    end)

    it("selects deletions anchored to the line that replaced them", function()
      -- new side: 10=ctx, deletions anchored at 11, 11=ctx2
      local hunk = hunks.parse("@@ -10,4 +10,2 @@\n ctx\n-gone1\n-gone2\n ctx2\n")[1]
      local none = hunks.select_range(hunk, 10, 10)
      assert.is_nil(none)

      local both = hunks.select_range(hunk, 11, 11)
      assert.same({ " ctx", "-gone1", "-gone2", " ctx2" }, both.lines)
    end)

    it("selects the matching side of a replacement", function()
      -- "-old1 -old2 +new1 +new2": deletions anchor at 10, additions at 10 and 11
      local hunk = hunks.parse("@@ -10,2 +10,2 @@\n-old1\n-old2\n+new1\n+new2\n")[1]
      local partial = hunks.select_range(hunk, 10, 10)
      assert.same({ "-old1", "-old2", "+new1" }, partial.lines)
      assert.equals(2, partial.old_count)
      assert.equals(1, partial.new_count)
    end)
  end)

  describe("inversion", function()
    it("swaps additions and deletions", function()
      local hunk = hunks.parse("@@ -10,2 +10,3 @@\n ctx\n-gone\n+new1\n+new2\n")[1]
      local inverted = hunks.invert(hunk)
      assert.same({ " ctx", "+gone", "-new1", "-new2" }, inverted.lines)
      assert.equals(hunk.new_start, inverted.old_start)
      assert.equals(hunk.old_start, inverted.new_start)
    end)
  end)

  describe("patch assembly", function()
    it("writes a well-formed single-file patch", function()
      local hunk = hunks.parse("@@ -10,2 +10,3 @@\n ctx\n+added\n ctx2\n")[1]
      local patch = assert(hunks.to_patch("src/f.lua", { hunk }))
      local lines = vim.split(patch, "\n", { plain = true })
      assert.equals("diff --git a/src/f.lua b/src/f.lua", lines[1])
      assert.equals("--- a/src/f.lua", lines[2])
      assert.equals("+++ b/src/f.lua", lines[3])
      assert.equals("@@ -10,2 +10,3 @@", lines[4])
      assert.equals("", lines[#lines]) -- patches end with a newline
    end)

    it("recomputes b-side offsets across several hunks", function()
      local list = hunks.parse(table.concat({
        "@@ -10,2 +10,4 @@",
        " a",
        "+x",
        "+y",
        " b",
        "@@ -30,2 +32,2 @@",
        " c",
        "-d",
        "+D",
      }, "\n"))
      local patch = assert(hunks.to_patch("f.lua", list))
      -- the first hunk adds two lines, so the second starts two lines later
      assert.is_not_nil(patch:find("@@ %-10,2 %+10,4 @@"))
      assert.is_not_nil(patch:find("@@ %-30,2 %+32,2 @@"))
    end)

    it("emits a /dev/null source for a new file", function()
      local hunk = hunks.parse("@@ -0,0 +1,2 @@\n+one\n+two\n")[1]
      local patch = assert(hunks.to_patch("new.lua", { hunk }, { new_file = true }))
      assert.is_not_nil(patch:find("new file mode 100644", 1, true))
      assert.is_not_nil(patch:find("--- /dev/null", 1, true))
      assert.is_not_nil(patch:find("@@ %-0,0 %+1,2 @@"))
    end)

    it("uses the original name on the a side of a rename", function()
      local hunk = hunks.parse("@@ -1 +1 @@\n-a\n+b\n")[1]
      local patch = assert(hunks.to_patch("new.lua", { hunk }, { old_path = "old.lua" }))
      assert.is_not_nil(patch:find("diff --git a/old.lua b/new.lua", 1, true))
      assert.is_not_nil(patch:find("--- a/old.lua", 1, true))
    end)

    it("refuses to build an empty patch", function()
      local patch, err = hunks.to_patch("f.lua", {})
      assert.is_nil(patch)
      assert.is_string(err)
    end)
  end)

  describe("path quoting", function()
    it("leaves ordinary and spaced names alone, as git does", function()
      assert.equals("a/src/f.lua", hunks.quote_path("a/src/f.lua"))
      assert.equals("a/my file.txt", hunks.quote_path("a/my file.txt"))
      assert.equals("a/café.txt", hunks.quote_path("a/café.txt"))
    end)

    it("c-quotes names containing quotes, backslashes or control characters", function()
      assert.equals('"a/say \\"hi\\".txt"', hunks.quote_path('a/say "hi".txt'))
      assert.equals('"a/back\\\\slash.txt"', hunks.quote_path("a/back\\slash.txt"))
      assert.equals('"a/tab\\there.txt"', hunks.quote_path("a/tab\there.txt"))
    end)
  end)

  describe("display rows", function()
    it("annotates each row with its line numbers", function()
      local list = hunks.parse("@@ -10,2 +20,3 @@\n ctx\n-gone\n+new\n+extra\n")
      local rows = hunks.to_display(list)
      assert.equals("header", rows[1].kind)
      assert.equals("context", rows[2].kind)
      assert.equals(10, rows[2].old_ln)
      assert.equals(20, rows[2].new_ln)
      assert.equals("delete", rows[3].kind)
      assert.equals(11, rows[3].old_ln)
      assert.is_nil(rows[3].new_ln)
      assert.equals("add", rows[4].kind)
      assert.equals(21, rows[4].new_ln)
      assert.equals(22, rows[5].new_ln)
    end)
  end)
end)
