import XCTest
import JustBash

final class BashTests: XCTestCase {
    // MARK: - Basic execution

    func testPersistsFilesystemAcrossExecCalls() async {
        let bash = Bash()
        let write = await bash.exec("echo hello > /tmp/greeting.txt")
        XCTAssertEqual(write.exitCode, 0)
        let read = await bash.exec("cat /tmp/greeting.txt")
        XCTAssertEqual(read.stdout, "hello\n")
    }

    func testResetsCwdAndEnvAcrossExecCalls() async {
        let bash = Bash(options: .init(env: ["NAME": "world"]))
        _ = await bash.exec("export NAME=swift; cd /tmp")
        let result = await bash.exec("printenv NAME; pwd")
        XCTAssertEqual(result.stdout, "world\n/home/user\n")
    }

    func testPipesAndConditionals() async {
        let bash = Bash()
        let result = await bash.exec("printf 'alpha\\nbeta\\n' | grep beta && echo done")
        XCTAssertEqual(result.stdout, "beta\ndone\n")
    }

    // MARK: - Control Flow

    func testIfThenElse() async {
        let bash = Bash()
        let result = await bash.exec("""
        if true; then
            echo yes
        else
            echo no
        fi
        """)
        XCTAssertEqual(result.stdout, "yes\n")
    }

    func testIfElif() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=2
        if [ "$x" = "1" ]; then
            echo one
        elif [ "$x" = "2" ]; then
            echo two
        else
            echo other
        fi
        """)
        XCTAssertEqual(result.stdout, "two\n")
    }

    func testForLoop() async {
        let bash = Bash()
        let result = await bash.exec("""
        for i in a b c; do
            echo $i
        done
        """)
        XCTAssertEqual(result.stdout, "a\nb\nc\n")
    }

    func testWhileLoop() async {
        let bash = Bash()
        let result = await bash.exec("""
        n=3
        while [ "$n" -gt "0" ]; do
            echo $n
            n=$((n - 1))
        done
        """)
        XCTAssertEqual(result.stdout, "3\n2\n1\n")
    }

    func testCaseStatement() async {
        let bash = Bash()
        let result = await bash.exec("""
        val=hello
        case $val in
            hi) echo greeting1 ;;
            hello) echo greeting2 ;;
            *) echo unknown ;;
        esac
        """)
        XCTAssertEqual(result.stdout, "greeting2\n")
    }

    // MARK: - Functions

    func testFunctionDefinition() async {
        let bash = Bash()
        let result = await bash.exec("""
        greet() {
            echo "Hello, $1!"
        }
        greet World
        """)
        XCTAssertEqual(result.stdout, "Hello, World!\n")
    }

    func testFunctionWithReturn() async {
        let bash = Bash()
        let result = await bash.exec("""
        check() {
            if [ "$1" = "yes" ]; then
                return 0
            fi
            return 1
        }
        check yes && echo passed
        check no || echo failed
        """)
        XCTAssertEqual(result.stdout, "passed\nfailed\n")
    }

    func testFunctionLocalVariables() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=global
        setx() {
            local x=local
            echo $x
        }
        setx
        echo $x
        """)
        XCTAssertEqual(result.stdout, "local\nglobal\n")
    }

    // MARK: - Command Substitution

    func testCommandSubstitution() async {
        let bash = Bash()
        let result = await bash.exec("""
        files=$(echo one two three)
        echo "got: $files"
        """)
        XCTAssertEqual(result.stdout, "got: one two three\n")
    }

    func testNestedCommandSubstitution() async {
        let bash = Bash()
        let result = await bash.exec("""
        echo "count: $(echo hello | wc -w)"
        """)
        XCTAssertEqual(result.stdout, "count: 1\n")
    }

    // MARK: - Special Variables

    func testExitCodeVariable() async {
        let bash = Bash()
        let result = await bash.exec("""
        true
        echo $?
        false
        echo $?
        """)
        XCTAssertEqual(result.stdout, "0\n1\n")
    }

    func testPositionalParams() async {
        let bash = Bash()
        let result = await bash.exec("""
        show() {
            echo "count=$#"
            echo "all=$@"
            echo "first=$1 second=$2"
        }
        show a b c
        """)
        XCTAssertEqual(result.stdout, "count=3\nall=a b c\nfirst=a second=b\n")
    }

    // MARK: - Arithmetic

    func testArithmeticExpansion() async {
        let bash = Bash()
        let result = await bash.exec("""
        echo $((2 + 3))
        echo $((10 / 3))
        echo $((7 % 4))
        """)
        XCTAssertEqual(result.stdout, "5\n3\n3\n")
    }

    func testArithmeticCommand() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=5
        if (( x > 3 )); then
            echo big
        fi
        """)
        XCTAssertEqual(result.stdout, "big\n")
    }

    // MARK: - Variable Operations

    func testDefaultValue() async {
        let bash = Bash()
        let result = await bash.exec("""
        echo ${unset:-default}
        x=hello
        echo ${x:-fallback}
        """)
        XCTAssertEqual(result.stdout, "default\nhello\n")
    }

    func testStringLength() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=hello
        echo ${#x}
        """)
        XCTAssertEqual(result.stdout, "5\n")
    }

    func testPrefixSuffixRemoval() async {
        let bash = Bash()
        let result = await bash.exec("""
        file=/path/to/file.txt
        echo ${file##*/}
        echo ${file%.*}
        """)
        XCTAssertEqual(result.stdout, "file.txt\n/path/to/file\n")
    }

    func testCaseModification() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=hello
        echo ${x^^}
        y=WORLD
        echo ${y,,}
        """)
        XCTAssertEqual(result.stdout, "HELLO\nworld\n")
    }

    // MARK: - Conditional Expressions

    func testConditionalExpression() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=hello
        if [[ $x == hello ]]; then
            echo match
        fi
        if [[ -z "" ]]; then
            echo empty
        fi
        """)
        XCTAssertEqual(result.stdout, "match\nempty\n")
    }

    func testFileTests() async {
        let bash = Bash(options: .init(files: ["/tmp/test.txt": "content"]))
        let result = await bash.exec("""
        if [[ -f /tmp/test.txt ]]; then echo exists; fi
        if [[ -d /tmp ]]; then echo isdir; fi
        if [[ ! -f /tmp/nonexistent ]]; then echo missing; fi
        """)
        XCTAssertEqual(result.stdout, "exists\nisdir\nmissing\n")
    }

    // MARK: - Comments and Multi-line

    func testComments() async {
        let bash = Bash()
        let result = await bash.exec("""
        # This is a comment
        echo hello # inline comment
        """)
        XCTAssertEqual(result.stdout, "hello\n")
    }

    func testMultiLineScript() async {
        let bash = Bash()
        let result = await bash.exec("""
        mkdir -p /tmp/demo
        echo hi > /tmp/demo/file.txt
        cat /tmp/demo/file.txt
        """)
        XCTAssertEqual(result.stdout, "hi\n")
    }

    // MARK: - Subshell

    func testSubshell() async {
        let bash = Bash()
        let result = await bash.exec("""
        x=outer
        (x=inner; echo $x)
        echo $x
        """)
        XCTAssertEqual(result.stdout, "inner\nouter\n")
    }

    // MARK: - Brace Group

    func testBraceGroup() async {
        let bash = Bash()
        let result = await bash.exec("""
        { echo a; echo b; } | wc -l
        """)
        XCTAssertEqual(result.stdout, "2\n")
    }

    // MARK: - Here String

    func testHereString() async {
        let bash = Bash()
        let result = await bash.exec("""
        cat <<< "hello world"
        """)
        XCTAssertEqual(result.stdout, "hello world\n")
    }

    // MARK: - Pipeline Negation

    func testPipelineNegation() async {
        let bash = Bash()
        let result = await bash.exec("""
        ! false && echo negated
        """)
        XCTAssertEqual(result.stdout, "negated\n")
    }

    // MARK: - Tilde Expansion

    func testTildeExpansion() async {
        let bash = Bash()
        let result = await bash.exec("echo ~")
        XCTAssertEqual(result.stdout, "/home/user\n")
    }
}
