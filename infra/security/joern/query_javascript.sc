// Joern security query script for JavaScript / TypeScript code property graphs.
//
// Usage (non-interactive):
//   joern --script query.sc \
//         --param cpgFile=artifacts/joern/javascript-cpg.bin \
//         --param outFile=artifacts/joern/javascript-results.json
//
// The output is a JSON array of finding objects consumed by joern_import.sh
// (which expects the Generic Findings Import format understood by DefectDojo).
//
// Queries are structured as (title, severity, description, traversal):
//   - severity follows DefectDojo values: Info / Low / Medium / High / Critical

import io.shiftleft.semanticcpg.language._
import io.shiftleft.codepropertygraph.generated.nodes._
import scala.util.{Try, Success, Failure}
import java.io.{PrintWriter, File}

// ---------------------------------------------------------------------------
// Helper: escape a string for JSON
// ---------------------------------------------------------------------------
def jsonStr(s: String): String = {
  val sb = new StringBuilder("\"")
  s.foreach {
    case '"'  => sb ++= "\\\""
    case '\\' => sb ++= "\\\\"
    case '\n' => sb ++= "\\n"
    case '\r' => sb ++= "\\r"
    case '\t' => sb ++= "\\t"
    case c if c.toInt < 0x20 => sb ++= f"\\u${c.toInt}%04x"
    case c    => sb += c
  }
  sb += '"'
  sb.toString
}

// ---------------------------------------------------------------------------
// Helper: build one JSON finding object
// ---------------------------------------------------------------------------
def finding(
    title:       String,
    severity:    String,
    description: String,
    filePath:    String,
    line:        Int
): String = {
  s"""{
  "title":       ${jsonStr(title)},
  "severity":    ${jsonStr(severity)},
  "description": ${jsonStr(description)},
  "file_path":   ${jsonStr(filePath)},
  "line":        $line
}"""
}

// ---------------------------------------------------------------------------
// Helper: normalize a file path (strip leading ./)
// ---------------------------------------------------------------------------
def cleanPath(p: String): String =
  if (p.startsWith("./")) p.drop(2) else p

// ---------------------------------------------------------------------------
// @main entry point — Joern calls this with --param values
// ---------------------------------------------------------------------------
@main def exec(cpgFile: String, outFile: String): Unit = {

  println(s"Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("CPG loaded. Running security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // -------------------------------------------------------------------------
  // Q1 — eval() usage (code injection risk)
  // JS: eval(userInput) can execute arbitrary code.
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .nameExact("eval")
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "Use of eval() — potential code injection",
          severity    = "High",
          description =
            s"eval() executes arbitrary code. If the argument contains " +
            s"user-controlled data this is a code injection vulnerability. " +
            s"Call: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q1 eval query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q2 — new Function(...) — same risk as eval
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .nameExact("<operator>.new")
      .filter(_.code.contains("Function"))
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "Use of new Function() — potential code injection",
          severity    = "High",
          description =
            s"new Function() constructs a function from a string, equivalent " +
            s"to eval(). If user input reaches this call it allows arbitrary " +
            s"code execution. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q2 new Function query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q3 — dangerouslySetInnerHTML — XSS risk in React
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .filter(_.code.contains("dangerouslySetInnerHTML"))
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "dangerouslySetInnerHTML usage — XSS risk",
          severity    = "High",
          description =
            s"dangerouslySetInnerHTML bypasses React's XSS protection. " +
            s"Ensure the HTML is sanitized (e.g. with DOMPurify) before " +
            s"passing it. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q3 dangerouslySetInnerHTML query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q4 — document.write() — classic DOM XSS sink
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .filter(c => c.code.contains("document.write"))
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "document.write() — DOM XSS sink",
          severity    = "High",
          description =
            s"document.write() is a dangerous DOM sink. If user-controlled " +
            s"data flows into it the page is vulnerable to DOM-based XSS. " +
            s"Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q4 document.write query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q5 — innerHTML assignment — DOM XSS sink
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .filter(c => c.code.contains("innerHTML") &&
                   (c.code.contains("=") || c.code.contains("+=")))
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "innerHTML assignment — DOM XSS sink",
          severity    = "Medium",
          description =
            s"Assigning to innerHTML can introduce DOM-based XSS if the " +
            s"value contains unsanitized user input. Prefer textContent or " +
            s"a sanitizer. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q5 innerHTML query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q6 — Unhandled promise (no .catch / no await)
  //      Targets the same pattern SonarQube flagged: functions that return a
  //      Promise without chaining .catch or using await.
  // -------------------------------------------------------------------------
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains(".then(") || c.code.contains("fetch(") ||
         c.code.contains("axios.") || c.code.contains("Promise."))
        && !c.code.contains(".catch(")
        && !c.code.contains("await ")
      )
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "Unhandled Promise — missing .catch() or await",
          severity    = "Low",
          description =
            s"A Promise is used without .catch() or await, so rejections are " +
            s"silently swallowed. This can hide errors and cause unpredictable " +
            s"behaviour. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q6 unhandled promise query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q7 — Hardcoded secrets in literals (API keys, tokens, passwords)
  // -------------------------------------------------------------------------
  Try {
    val secretPattern =
      "(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|password|passwd|auth[_-]?token)\\s*[:=]\\s*['\"]([^'\"]{6,})['\"]".r

    cpg.literal
      .filter(l => secretPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.file.name.exists(_.contains("node_modules")))
      .filterNot(l => l.code.contains("process.env"))
      .l
      .foreach { l =>
        results += finding(
          title       = "Potential hardcoded secret in source code",
          severity    = "High",
          description =
            s"A literal value appears to contain a hardcoded credential or " +
            s"secret key. Secrets should be read from environment variables " +
            s"or a secrets manager at runtime. Code: ${l.code.take(80)}...",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q7 hardcoded secrets query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Q8 — console.log leaking sensitive identifiers
  // -------------------------------------------------------------------------
  Try {
    val sensitivePattern =
      "(?i)(password|token|secret|key|credential|auth)".r

    cpg.call
      .nameExact("console.log")
      .filter(c => sensitivePattern.findFirstIn(c.code).isDefined)
      .filterNot(c => c.file.name.exists(_.contains("node_modules")))
      .l
      .foreach { c =>
        results += finding(
          title       = "Sensitive data logged to console",
          severity    = "Medium",
          description =
            s"console.log() appears to log potentially sensitive data " +
            s"(password, token, secret, key). Remove or redact before " +
            s"production. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match {
    case Failure(e) => println(s"[WARN] Q8 console.log query failed: ${e.getMessage}")
    case _          =>
  }

  // -------------------------------------------------------------------------
  // Write output
  // -------------------------------------------------------------------------
  val count = results.size

  if (count == 0) {
    println("No findings from security queries.")
    // Write an empty array so joern_import.sh sees the file and exits cleanly.
    new PrintWriter(new File(outFile)) {
      write("[]")
      close()
    }
  } else {
    println(s"Writing $count finding(s) to $outFile")
    new PrintWriter(new File(outFile)) {
      write("[\n")
      write(results.mkString(",\n"))
      write("\n]\n")
      close()
    }
    println(s"Done — $count finding(s) written to $outFile")
  }
}
