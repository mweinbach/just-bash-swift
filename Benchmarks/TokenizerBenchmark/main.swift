import Foundation
import JustBashCore

// Generate a large shell script for benchmarking
func generateLargeScript(lines: Int) -> String {
    var script = "#!/bin/bash\n"
    
    for i in 0..<lines {
        let lineType = i % 10
        switch lineType {
        case 0:
            script += "echo 'Hello World'\n"
        case 1:
            script += "VAR\(i)=value\(i)\n"
        case 2:
            script += "if [ $VAR\(i) == 'test' ]; then\n"
        case 3:
            script += "    echo 'Condition met'\n"
        case 4:
            script += "fi\n"
        case 5:
            script += "for i in 1 2 3 4 5; do\n"
        case 6:
            script += "    echo $i > /tmp/output\(i).txt\n"
        case 7:
            script += "done\n"
        case 8:
            script += "cat /tmp/file\(i).txt | grep 'pattern' | sort > /tmp/sorted\(i).txt\n"
        case 9:
            script += "[[ -f /tmp/test\(i) ]] && echo 'exists' || echo 'missing'\n"
        default:
            script += "# Comment line \(i)\n"
        }
    }
    
    return script
}

// Benchmark function
func benchmark(name: String, iterations: Int, script: String) -> Double {
    let parser = ShellParser()
    
    // Warmup
    _ = try? parser.parse(script)
    
    let start = Date()
    for _ in 0..<iterations {
        _ = try? parser.parse(script)
    }
    let end = Date()
    
    let totalTime = end.timeIntervalSince(start)
    let avgTime = totalTime / Double(iterations)
    
    print("  \(name): \(String(format: "%.4f", totalTime))s total, \(String(format: "%.4f", avgTime * 1000))ms avg (\(iterations) iterations)")
    return totalTime
}

// Run benchmarks
@main
struct TokenizerBenchmark {
    static func main() {
        print("Tokenizer Performance Benchmark")
        print("================================\n")
        
        let scriptSizes = [100, 500, 1000, 2000, 5000]
        
        for size in scriptSizes {
            let script = generateLargeScript(lines: size)
            let charCount = script.count
            let lines = script.split(separator: "\n").count
            
            print("Script size: \(size) lines (\(charCount) chars, \(lines) actual lines)")
            
            // Fewer iterations for larger scripts
            let iterations = size <= 500 ? 50 : (size <= 2000 ? 20 : 10)
            _ = benchmark(name: "Tokenize", iterations: iterations, script: script)
            print("")
        }
        
        print("Benchmark complete!")
    }
}
