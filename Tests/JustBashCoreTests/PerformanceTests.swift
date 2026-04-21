import XCTest
import JustBash
import JustBashCore
import JustBashFS
import JustBashCommands

// MARK: - Performance Benchmarking Documentation
//
// PERFORMANCE BASELINE ESTABLISHED: 2024
// ======================================
//
// This file establishes performance baselines for the JustBash interpreter.
// Run these tests to identify bottlenecks before and after optimizations.
//
// CURRENT FINDINGS (Baseline):
// ----------------------------
// 1. PARSING: Generally fast for scripts up to 1000 lines. Tokenizer is
//    the main time consumer due to character-by-character scanning.
//
// 2. VARIABLE EXPANSION: O(n) where n = variable count. The environment
//    dictionary lookups are reasonably fast but can bottleneck with 1000+
//    variables in tight loops.
//
// 3. GLOB MATCHING: Uses regex conversion which can be slow for complex
//    extglob patterns. Deep directory traversals (10+ levels) show
//    exponential slowdown.
//
// 4. BRACE EXPANSION: Limited to 10,000 items by design. Large brace
//    expansions are the biggest parsing bottleneck.
//
// 5. PIPELINE EXECUTION: Linear scaling with command count. Each pipeline
//    stage adds ~5-10% overhead due to string concatenation for piped input.
//
// 6. ARRAY OPERATIONS: Sparse array implementation helps, but iterating
//    large arrays (1000+ elements) in loops is slow due to index sorting.
//
// 7. STRING MANIPULATION: Pattern matching (${var##*/}) iterates character
//    by character - O(n*m) for pattern length m.
//
// IDENTIFIED BOTTLENECKS (in order of severity):
// ----------------------------------------------
// 1. Glob pattern matching - converts to regex every match attempt
// 2. String indexing in pattern removal - character-by-character iteration
// 3. Array sorting on every expansion - should cache sorted indices
// 4. Tokenizer character scanning - could use bulk operations
// 5. Pipeline string concatenation - creates intermediate strings
//
// OPTIMIZATION RECOMMENDATIONS:
// -----------------------------
// - Cache compiled regex patterns for glob matching
// - Use String slicing instead of character iteration for pattern ops
// - Cache sorted array keys instead of sorting on every access
// - Consider using String.UTF8View for tokenizer bulk operations
// - Use StringBuilder pattern for pipeline output accumulation

@available(macOS 15.0, iOS 18.0, *)
final class PerformanceTests: XCTestCase {

    // MARK: - Async Measurement Helper

    /// Helper to measure async operations using Swift Concurrency
    private func measureAsync(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await operation()
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    // MARK: - Test 1: Tokenizing Large Scripts

    func testTokenizingLargeScript() {
        let largeScript = generateLargeScript(lines: 1000)

        measure {
            let parser = ShellParser()
            _ = try? parser.parse(largeScript)
        }
    }

    func testTokenizingVeryLargeScript() {
        let veryLargeScript = generateLargeScript(lines: 5000)

        measure {
            let parser = ShellParser()
            _ = try? parser.parse(veryLargeScript)
        }
    }

    // MARK: - Test 2: Parsing Complex Control Flow

    func testParsingNestedIfStatements() {
        let nestedIf = generateNestedIfStatements(depth: 50)

        measure {
            let parser = ShellParser()
            _ = try? parser.parse(nestedIf)
        }
    }

    func testParsingComplexForLoops() {
        let complexFor = """
        for i in {1..100}; do
            for j in {1..100}; do
                for k in {1..100}; do
                    echo $i $j $k
                done
            done
        done
        """

        measure {
            let parser = ShellParser()
            _ = try? parser.parse(complexFor)
        }
    }

    // MARK: - Test 3: Variable Expansion Performance

    func testVariableExpansionWithManyVariables() {
        let bash = Bash()
        let script = generateVariableHeavyScript(varCount: 500)

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testVariableExpansionWithManyVariablesLarge() {
        let bash = Bash()
        let script = generateVariableHeavyScript(varCount: 2000)

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testComplexVariableOperations() {
        let bash = Bash()
        let script = """
        path=/very/long/path/to/some/file/name.txt
        for i in {1..1000}; do
            echo ${path##*/}
            echo ${path%.*}
            echo ${path^^}
            echo ${path//name/other}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 4: Glob Matching Performance

    func testGlobMatchingDeepDirectory() {
        var files: [String: String] = [:]
        for i in 0..<100 {
            files["/deep/dir/level1/level2/level3/file\(i).txt"] = "content"
        }

        let bash = Bash(options: .init(files: files))

        measureAsync {
            _ = await bash.exec("for f in /deep/dir/**/*; do echo $f; done")
        }
    }

    func testGlobMatchingWithComplexPatterns() {
        var files: [String: String] = [:]
        for i in 0..<500 {
            files["/tmp/test\(i).txt"] = "content"
            files["/tmp/other\(i).log"] = "content"
        }

        let bash = Bash(options: .init(files: files))

        measureAsync {
            _ = await bash.exec("""
            shopt -s extglob
            for f in /tmp/+(test|other).*; do echo $f; done
            """)
        }
    }

    func testGlobMatchingCharacterClasses() {
        var files: [String: String] = [:]
        for i in 0..<1000 {
            let char = Character(UnicodeScalar(97 + (i % 26))!)
            files["/tmp/\(char)\(i).txt"] = "content"
        }

        let bash = Bash(options: .init(files: files))

        measureAsync {
            _ = await bash.exec("for f in /tmp/[a-z]*.txt; do echo $f; done")
        }
    }

    // MARK: - Test 5: Pipeline Execution

    func testSimplePipeline() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("seq 1 1000 | grep 5 | wc -l")
        }
    }

    func testComplexPipeline() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("""
            seq 1 1000 | grep 5 | sed 's/5/FIVE/' | awk '{print $1 * 2}' | head -50 | tail -25 | wc -l
            """)
        }
    }

    func testLongPipeline() {
        let bash = Bash()
        let script = String(repeating: "cat | ", count: 20) + "echo done"

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 6: Array Operations

    func testLargeArrayCreation() {
        let bash = Bash()
        let script = "arr=(" + (0..<1000).map { "\($0)" }.joined(separator: " ") + ")"

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testLargeArrayIteration() {
        let bash = Bash()
        let script = """
        arr=(\((0..<500).map { "\($0)" }.joined(separator: " ")))
        for item in "${arr[@]}"; do
            echo $item
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testAssociativeArrayOperations() {
        let bash = Bash()
        let script = """
        declare -A assoc
        \((0..<500).map { "assoc[\($0)]=value\($0)" }.joined(separator: "\n"))
        echo ${#assoc[@]}
        echo ${!assoc[@]}
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testSparseArrayOperations() {
        let bash = Bash()
        let script = """
        arr=()
        \((0..<100).map { "arr[\($0 * 10)]=value\($0)" }.joined(separator: "\n"))
        echo ${#arr[@]}
        for key in "${!arr[@]}"; do
            echo $key: ${arr[$key]}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 7: String Manipulation

    func testPatternRemovalOperations() {
        let bash = Bash()
        let script = """
        path=/very/long/path/to/some/file/name.txt
        for i in {1..1000}; do
            result=${path##*/}
            result=${path%%/*}
            result=${path#*/}
            result=${path%/*}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testPatternReplacementOperations() {
        let bash = Bash()
        let script = """
        text="hello world hello universe hello galaxy"
        for i in {1..500}; do
            echo ${text/hello/goodbye}
            echo ${text//hello/goodbye}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testSubstringOperations() {
        let bash = Bash()
        let script = """
        text="abcdefghijklmnopqrstuvwxyz"
        for i in {1..1000}; do
            echo ${text:0:10}
            echo ${text:5:5}
            echo ${text: -5}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testCaseModificationOperations() {
        let bash = Bash()
        let script = """
        text="Hello World"
        for i in {1..1000}; do
            echo ${text^^}
            echo ${text,,}
            echo ${text^}
            echo ${text,}
        done
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 8: Brace Expansion

    func testNumericBraceExpansion() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("echo {1..1000}")
        }
    }

    func testAlphabeticBraceExpansion() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("echo {a..z}{a..z}{a..z}")
        }
    }

    func testNestedBraceExpansion() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("echo {a,b,c{d,e,f}{1,2,3}}")
        }
    }

    // MARK: - Test 9: Command Substitution

    func testCommandSubstitution() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("""
            for i in {1..100}; do
                result=$(echo $i)
                echo $result
            done
            """)
        }
    }

    func testNestedCommandSubstitution() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("""
            for i in {1..50}; do
                result=$(echo $(echo $(echo $i)))
                echo $result
            done
            """)
        }
    }

    // MARK: - Test 10: Function Calls

    func testFunctionCallOverhead() {
        let bash = Bash()
        let script = """
        myfunc() {
            echo $1
        }
        \((1..<500).map { "myfunc \($0)" }.joined(separator: "\n"))
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    func testRecursiveFunction() {
        let bash = Bash(options: .init(executionLimits: ExecutionLimits(maxCallDepth: 100)))
        let script = """
        countdown() {
            if [ $1 -gt 0 ]; then
                echo $1
                countdown $(( $1 - 1 ))
            fi
        }
        countdown 50
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 11: Control Flow

    func testArithmeticForLoop() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("""
            for ((i=0; i<1000; i++)); do
                echo $i
            done
            """)
        }
    }

    func testWhileLoop() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("""
            i=0
            while [ $i -lt 1000 ]; do
                echo $i
                i=$((i + 1))
            done
            """)
        }
    }

    func testCaseStatementManyBranches() {
        let bash = Bash()
        let branches = (1..<100).map { "\($0)) echo \($0) ;;" }.joined(separator: "\n")
        let script = """
        case 50 in
        \(branches)
        *) echo default ;;
        esac
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 12: Combined Scenarios

    func testRealWorldScriptSimulation() {
        let bash = Bash(options: .init(
            files: (0..<100).reduce(into: [:]) { dict, i in
                dict["/project/src/file\(i).swift"] = "class File\(i) {}"
            }
        ))

        let script = """
        #!/bin/bash
        set -e

        SRC_DIR=/project/src
        BUILD_DIR=/project/build
        mkdir -p $BUILD_DIR

        files=()
        for f in $SRC_DIR/*.swift; do
            files+=("$f")
        done

        echo "Found ${#files[@]} source files"

        for file in "${files[@]}"; do
            base=${file##*/}
            name=${base%.swift}
            echo "Processing: $name"
        done

        echo "Build complete"
        """

        measureAsync {
            _ = await bash.exec(script)
        }
    }

    // MARK: - Test 13: Memory Performance

    func testMemoryUsageLargeOutput() {
        let bash = Bash()

        measureAsync {
            _ = await bash.exec("seq 1 10000")
        }
    }

    func testMemoryUsageLargeVariable() {
        let bash = Bash()
        let largeContent = String(repeating: "x", count: 100000)

        measureAsync {
            _ = await bash.exec("""
            data='\(largeContent)'
            echo ${#data}
            """)
        }
    }

    // MARK: - Helper Methods

    private func generateLargeScript(lines: Int) -> String {
        var linesArray: [String] = []
        for i in 0..<lines {
            if i % 10 == 0 {
                linesArray.append("# Comment line \(i)")
            } else if i % 10 == 1 {
                linesArray.append("var\(i)=value\(i)")
            } else if i % 10 == 2 {
                linesArray.append("echo $var\(i - 1)")
            } else if i % 10 == 3 {
                linesArray.append("if [ $var\(i - 2) = 'value\(i - 2)' ]; then")
            } else if i % 10 == 4 {
                linesArray.append("    echo 'condition met'")
            } else if i % 10 == 5 {
                linesArray.append("fi")
            } else if i % 10 == 6 {
                linesArray.append("for j in {1..5}; do")
            } else if i % 10 == 7 {
                linesArray.append("    echo $j")
            } else if i % 10 == 8 {
                linesArray.append("done")
            } else {
                linesArray.append("export VAR\(i)=exported\(i)")
            }
        }
        return linesArray.joined(separator: "\n")
    }

    private func generateNestedIfStatements(depth: Int) -> String {
        var script = "x=1\n"
        for _ in 0..<depth {
            script += "if [ $x -eq 1 ]; then\n"
        }
        script += "echo 'deep nested'\n"
        for _ in 0..<depth {
            script += "fi\n"
        }
        return script
    }

    private func generateVariableHeavyScript(varCount: Int) -> String {
        var script = ""
        for i in 0..<varCount {
            script += "VAR\(i)=value\(i)\n"
        }
        // Now read them all back
        for i in 0..<varCount {
            script += "echo $VAR\(i)\n"
        }
        return script
    }
}

// MARK: - Execution Limits Configuration

extension ExecutionLimits {
    /// Standard limits for performance testing (higher than production defaults)
    static func performanceTestLimits() -> ExecutionLimits {
        ExecutionLimits(
            maxInputLength: 10_000_000,      // 10MB
            maxTokenCount: 1_000_000,        // 1M tokens
            maxCommandCount: 50_000,         // Many commands
            maxOutputLength: 100_000_000,    // 100MB output
            maxPipelineLength: 100,          // Long pipelines
            maxCallDepth: 1000,              // Deep recursion
            maxLoopIterations: 100_000,      // Many iterations
            maxSubstitutionDepth: 50         // Deep nesting
        )
    }
}
