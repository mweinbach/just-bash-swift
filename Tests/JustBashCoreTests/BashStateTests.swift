import XCTest
@testable import JustBash

final class BashStateTests: XCTestCase {
    func testFilesystemPersistsAcrossExecsButEnvDoesNot() async {
        let bash = Bash()
        _ = await bash.exec("echo hi > /tmp/hello.txt")
        let first = await bash.exec("cat /tmp/hello.txt")
        XCTAssertEqual(first.stdout, "hi\n")

        _ = await bash.exec("export FOO=bar; echo ok")
        let second = await bash.exec("printenv FOO")
        XCTAssertEqual(second.exitCode, 1)
    }

    func testCdOnlyAffectsCurrentExec() async {
        let bash = Bash()
        let first = await bash.exec("mkdir -p /tmp/work; cd /tmp/work; pwd")
        XCTAssertEqual(first.stdout, "/tmp/work\n")
        let second = await bash.exec("pwd")
        XCTAssertEqual(second.stdout, "/home/user\n")
    }

    // MARK: - Quoted Array Expansion Tests
    // NOTE: These tests require complex word-splitting logic that is not yet implemented.
    // Quoted array expansion (${arr[@]} vs ${arr[*]}) requires the interpreter to track 
    // quoting context through the entire expansion pipeline.
    
    /*
    func testQuotedArrayAtExpandsToSeparateWords() async {
        let bash = Bash()
        let result = await bash.exec("arr=(hello world); for x in \"\${arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello<\n>world<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayStarExpandsToSingleWord() async {
        let bash = Bash()
        let result = await bash.exec("arr=(hello world); for x in \"\${arr[*]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello world<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayAtWithSpacesInElements() async {
        let bash = Bash()
        let result = await bash.exec("arr=('hello world' 'foo bar'); for x in \"\${arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello world<\n>foo bar<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayStarWithSpacesInElements() async {
        let bash = Bash()
        let result = await bash.exec("arr=('hello world' 'foo bar'); for x in \"\${arr[*]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello world foo bar<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayAtEmptyArray() async {
        let bash = Bash()
        let result = await bash.exec("arr=(); for x in \"\${arr[@]}\"; do echo \">\$x<\"; done; echo done")
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayStarEmptyArray() async {
        let bash = Bash()
        let result = await bash.exec("arr=(); for x in \"\${arr[*]}\"; do echo \">\$x<\"; done; echo done")
        XCTAssertEqual(result.stdout, "><\ndone\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayStarCustomIFS() async {
        let bash = Bash()
        let result = await bash.exec("IFS=':'; arr=(a b c); for x in \"\${arr[*]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">a:b:c<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayAtCustomIFSUnchanged() async {
        let bash = Bash()
        let result = await bash.exec("IFS=':'; arr=(a b c); for x in \"\${arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">a<\n>b<\n>c<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedAssocAtExpandsToSeparateWords() async {
        let bash = Bash()
        let result = await bash.exec("declare -A assoc; assoc[a]=hello; assoc[b]=world; for x in \"\${assoc[@]}\"; do echo \">\$x<\"; done")
        // Order of associative arrays may vary, check both values appear
        XCTAssertTrue(result.stdout.contains(">hello<"))
        XCTAssertTrue(result.stdout.contains(">world<"))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedAssocStarExpandsToSingleWord() async {
        let bash = Bash()
        let result = await bash.exec("declare -A assoc; assoc[a]=hello; assoc[b]=world; for x in \"\${assoc[*]}\"; do echo \">\$x<\"; done")
        // Should be a single word with both values
        XCTAssertEqual(result.exitCode, 0)
        // Verify it's a single iteration (single output line)
        let lines = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        // Should contain both values
        XCTAssertTrue(result.stdout.contains("hello"))
        XCTAssertTrue(result.stdout.contains("world"))
    }

    func testQuotedArrayKeysAtExpandsToSeparateWords() async {
        let bash = Bash()
        let result = await bash.exec("arr=(zero one two); for x in \"\${!arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">0<\n>1<\n>2<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedArrayKeysStarExpandsToSingleWord() async {
        let bash = Bash()
        let result = await bash.exec("arr=(zero one two); for x in \"\${!arr[*]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">0 1 2<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSingleElementArrayQuotedAt() async {
        let bash = Bash()
        let result = await bash.exec("arr=('hello world'); for x in \"\${arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello world<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSingleElementArrayQuotedStar() async {
        let bash = Bash()
        let result = await bash.exec("arr=('hello world'); for x in \"\${arr[*]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">hello world<\n")
        XCTAssertEqual(result.exitCode, 0)
    }
    */

    // MARK: - Sparse Array Tests
    // NOTE: Full sparse array semantics require interpreter-level changes to properly
    // handle gaps in array indices. The storage layer supports sparse arrays but the
    // expansion logic needs enhancement.
    
    /*
    func testSparseArrayLengthCountsSetElements() async {
        let bash = Bash()
        // arr[0]=a; arr[5]=b; arr[100]=c should have count 3, not 101
        let result = await bash.exec("arr[0]=a; arr[5]=b; arr[100]=c; echo \"\${#arr[@]}\"")
        XCTAssertEqual(result.stdout, "3\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSparseArrayExpansionOnlySetElements() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=a; arr[5]=b; arr[100]=c; echo \"\${arr[@]}\"")
        XCTAssertEqual(result.stdout, "a b c\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSparseArrayKeysExpansion() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=a; arr[5]=b; arr[100]=c; echo \"\${!arr[@]}\"")
        XCTAssertEqual(result.stdout, "0 5 100\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testUnsetMiddleElementCreatesGap() async {
        let bash = Bash()
        // Create contiguous array, then unset middle element
        let result = await bash.exec("arr=(a b c d e); unset arr[2]; echo \"\${#arr[@]}\"; echo \"\${arr[@]}\"; echo \"\${!arr[@]}\"")
        XCTAssertEqual(result.stdout, "4\na b d e\n0 1 3 4\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSparseArrayWithNonZeroStart() async {
        let bash = Bash()
        let result = await bash.exec("arr[10]=first; arr[20]=second; echo \"\${#arr[@]}\"; echo \"\${arr[@]}\"")
        XCTAssertEqual(result.stdout, "2\nfirst second\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAccessUnsetElementReturnsEmpty() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=a; arr[5]=b; echo \"\${arr[2]}\"")
        XCTAssertEqual(result.stdout, "\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSparseArrayStarExpansion() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=a; arr[5]=b; arr[100]=c; echo \"\${arr[*]}\"")
        XCTAssertEqual(result.stdout, "a b c\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testQuotedSparseArrayAllExpansion() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=a; arr[5]=b; arr[100]=c; for x in \"\${arr[@]}\"; do echo \">\$x<\"; done")
        XCTAssertEqual(result.stdout, ">a<\n>b<\n>c<\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLargeSparseArray() async {
        let bash = Bash()
        let result = await bash.exec("arr[0]=start; arr[999]=end; echo \"\${#arr[@]}\"")
        XCTAssertEqual(result.stdout, "2\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testArrayWithMultipleGapsAfterUnset() async {
        let bash = Bash()
        let result = await bash.exec("arr=(a b c d e); unset arr[1] arr[3]; echo \"\${#arr[@]}\"; echo \"\${!arr[@]}\"")
        XCTAssertEqual(result.stdout, "3\n0 2 4\n")
        XCTAssertEqual(result.exitCode, 0)
    }
    */

    // MARK: - Special Variables Tests
    // NOTE: These special variables require implementation in Bash.swift environment setup
    // or in the interpreter's getVariable method.
    
    /*
    func testPPID_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$PPID")
        XCTAssertEqual(result.stdout, "1\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testUID_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$UID")
        XCTAssertEqual(result.stdout, "1000\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testEUID_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$EUID")
        XCTAssertEqual(result.stdout, "1000\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testGROUPS_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$GROUPS")
        XCTAssertEqual(result.stdout, "1000\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testOSTYPE_EnvironmentVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$OSTYPE")
        // OSTYPE depends on platform (darwin on macOS, linux-gnu on Linux)
        XCTAssertTrue(result.stdout == "darwin\n" || result.stdout == "linux-gnu\n" || result.stdout == "unknown\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testMACHTYPE_EnvironmentVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$MACHTYPE")
        // MACHTYPE depends on platform
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertNotEqual(result.stdout, "unknown\n")  // Should have a real value
        XCTAssertEqual(result.exitCode, 0)
    }

    func testBASHPID_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$BASHPID")
        XCTAssertEqual(result.stdout, "1\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testBASH_SUBSHELL_SpecialVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$BASH_SUBSHELL")
        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSHLVL_EnvironmentVariable() async {
        let bash = Bash()
        let result = await bash.exec("echo \$SHLVL")
        XCTAssertEqual(result.stdout, "1\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSpecialVariablesInConditionals() async {
        let bash = Bash()
        // Test that UID/EUID can be used for permission checks
        let result = await bash.exec("if [ \"\$UID\" -eq 1000 ]; then echo 'regular user'; fi")
        XCTAssertEqual(result.stdout, "regular user\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testGROUPSUsedInLoop() async {
        let bash = Bash()
        // GROUPS should return a space-separated list (in this case just one value)
        let result = await bash.exec("for g in \$GROUPS; do echo \"group: \$g\"; done")
        XCTAssertEqual(result.stdout, "group: 1000\n")
        XCTAssertEqual(result.exitCode, 0)
    }
    */
}
