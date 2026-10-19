// Joern security query script — Go.
//
// Usage:
//   joern --script query_go.sc \
//         --param cpgFile=<cpg.bin> --param outFile=<out.json>

import io.shiftleft.semanticcpg.language._
import scala.util.{Try, Failure}
import java.io.{PrintWriter, File}

def jsonStr(s: String): String =
  "\"" + s.flatMap {
    case '"'  => "\\\""; case '\\' => "\\\\"
    case '\n' => "\\n";  case '\r' => "\\r"; case '\t' => "\\t"
    case c if c.toInt < 0x20 => f"\\u${c.toInt}%04x"
    case c    => c.toString
  } + "\""

def cleanPath(p: String): String = if (p.startsWith("./")) p.drop(2) else p

def finding(title: String, severity: String, description: String,
            filePath: String, line: Int): String =
  s"""{"title":${jsonStr(title)},"severity":${jsonStr(severity)},"description":${jsonStr(description)},"file_path":${jsonStr(filePath)},"line":$line}"""

def writeResults(outFile: String, results: Seq[String]): Unit = {
  val pw = new PrintWriter(new File(outFile))
  if (results.isEmpty) pw.write("[]")
  else { pw.write("[\n"); pw.write(results.mkString(",\n")); pw.write("\n]\n") }
  pw.close()
}

@main def exec(cpgFile: String, outFile: String): Unit = {
  println(s"[golang] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[golang] Running Go security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — os/exec.Command with concatenated arguments
  Try {
    cpg.call
      .filter(c => c.code.contains("exec.Command") || c.code.contains("exec.CommandContext"))
      .filter(c => c.code.contains(" + ") || c.code.contains("fmt.Sprintf"))
      .l.foreach { c =>
        results += finding("exec.Command with dynamic arguments — command injection", "High",
          s"exec.Command is called with a dynamically built command string. Use a fixed " +
          s"command name and pass user input as separate arguments to avoid injection. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q1: ${e.getMessage}"); case _ => }

  // Q2 — SQL injection via Sprintf/concatenation in db queries
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains(".Query(") || c.code.contains(".QueryRow(") ||
         c.code.contains(".Exec(") || c.code.contains(".QueryContext("))
        && (c.code.contains("fmt.Sprintf") || c.code.contains(" + "))
      )
      .l.foreach { c =>
        results += finding("SQL injection — dynamic query string", "Critical",
          s"A database query is built using fmt.Sprintf or concatenation. " +
          s"Use parameterised queries with ? or $1 placeholders. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q2: ${e.getMessage}"); case _ => }

  // Q3 — http.Get / http.Post with user-controlled URL (SSRF)
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains("http.Get(") || c.code.contains("http.Post(") ||
         c.code.contains("http.NewRequest("))
        && (c.code.contains(" + ") || c.code.contains("fmt.Sprintf") ||
            c.code.contains("r.URL") || c.code.contains("r.FormValue"))
      )
      .l.foreach { c =>
        results += finding("Possible SSRF — user-controlled HTTP request URL", "High",
          s"An outbound HTTP call is made with a URL that may include user-controlled input. " +
          s"Validate and allow-list the target URL to prevent SSRF. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q3: ${e.getMessage}"); case _ => }

  // Q4 — ioutil.ReadFile / os.ReadFile with path from user input
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains("ioutil.ReadFile") || c.code.contains("os.ReadFile") ||
         c.code.contains("os.Open("))
        && (c.code.contains(" + ") || c.code.contains("r.URL") || c.code.contains("r.FormValue"))
      )
      .l.foreach { c =>
        results += finding("Path traversal — user input in file path", "High",
          s"A file is opened with a path that may include user-controlled data. " +
          s"Canonicalise the path with filepath.Clean and verify it stays within the base dir. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q4: ${e.getMessage}"); case _ => }

  // Q5 — Weak TLS: InsecureSkipVerify = true
  Try {
    cpg.call
      .filter(c => c.code.contains("InsecureSkipVerify") && c.code.contains("true"))
      .l.foreach { c =>
        results += finding("TLS certificate verification disabled", "High",
          s"InsecureSkipVerify: true disables TLS certificate verification, enabling MITM attacks. " +
          s"Remove this in production and use a proper CA bundle. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q5: ${e.getMessage}"); case _ => }

  // Q6 — math/rand instead of crypto/rand for security tokens
  Try {
    cpg.call
      .filter(c => c.code.contains("rand.Int") || c.code.contains("rand.Intn") ||
                   c.code.contains("rand.New("))
      .filterNot(c => c.code.contains("crypto/rand"))
      .l.foreach { c =>
        results += finding("math/rand used — not cryptographically secure", "Medium",
          s"math/rand is a pseudo-random generator. Use crypto/rand for tokens, " +
          s"nonces, session IDs, and keys. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q6: ${e.getMessage}"); case _ => }

  // Q7 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\\s*[:=]\\s*\"([^\"]{6,})\"".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("os.Getenv") || l.code.contains("os.LookupEnv"))
      .l.foreach { l =>
        results += finding("Hardcoded credential in Go source", "High",
          s"Load secrets from environment variables or a vault. Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] go Q7: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[golang] Done — $count finding(s) written to $outFile")
}
