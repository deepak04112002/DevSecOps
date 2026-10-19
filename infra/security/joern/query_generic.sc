// Joern generic security query script.
// Language-agnostic fallback used when no language-specific query script
// exists (Go, C#, Ruby, Rust, Swift, ABAP, ...). It focuses on findings
// that are meaningful regardless of language: hardcoded secrets/credentials.
//
// Usage:
//   joern --script query_generic.sc \
//         --param cpgFile=<cpg.bin> --param outFile=<out.json>

import io.shiftleft.semanticcpg.language._
import scala.util.{Try, Failure}
import java.io.{PrintWriter, File}

// ---- JSON helpers -------------------------------------------------------
def jsonStr(s: String): String =
  "\"" + s.flatMap {
    case '"'  => "\\\""
    case '\\' => "\\\\"
    case '\n' => "\\n"
    case '\r' => "\\r"
    case '\t' => "\\t"
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

// ---- @main --------------------------------------------------------------
@main def exec(cpgFile: String, outFile: String): Unit = {
  println(s"[generic] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[generic] Running language-agnostic security queries...")

  val results = collection.mutable.ListBuffer[String]()
  val notLib  = (name: Option[String]) => !name.exists(_.contains("node_modules"))

  // Q1 — Hardcoded credentials in string literals.
  // Matches common secret-like assignments: api_key, secret, token, password...
  Try {
    val credPattern =
      "(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|client[_-]?secret)\\s*[:=]\\s*['\"]([^'\"]{6,})['\"]".r

    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filter(l => notLib(l.file.name.headOption))
      .filterNot(l => l.code.contains("process.env") || l.code.contains("getenv") ||
                      l.code.contains("System.getenv") || l.code.contains("os.environ"))
      .l
      .foreach { l =>
        results += finding(
          title       = "Hardcoded credential in source code",
          severity    = "High",
          description =
            s"A literal appears to assign a credential (api key, secret, token, or password). " +
            s"Move secrets to environment variables or a secrets manager. Code: ${l.code.take(80)}",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] generic Q1 secrets: ${e.getMessage}"); case _ => }

  // Q2 — AWS access key IDs (AKIA...).
  Try {
    cpg.literal
      .filter(_.code.matches(".*AKIA[0-9A-Z]{16}.*"))
      .filter(l => notLib(l.file.name.headOption))
      .l
      .foreach { l =>
        results += finding(
          title       = "Hardcoded AWS access key ID",
          severity    = "Critical",
          description =
            s"An AWS access key ID (AKIA...) was found hardcoded in source. " +
            s"Rotate the key immediately and load it from the environment/secrets manager.",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] generic Q2 AKIA: ${e.getMessage}"); case _ => }

  // Q3 — Embedded private keys (PEM headers).
  Try {
    cpg.literal
      .filter(_.code.contains("-----BEGIN"))
      .filter(l => notLib(l.file.name.headOption))
      .l
      .foreach { l =>
        results += finding(
          title       = "Embedded private key / PEM block",
          severity    = "Critical",
          description =
            s"A PEM-encoded private key block appears to be hardcoded. " +
            s"Remove it from source and load from a secrets manager.",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] generic Q3 PEM: ${e.getMessage}"); case _ => }

  // Q4 — Generic high-entropy secret assigned to a credential-looking variable.
  Try {
    val longSecret = "(?i)(key|token|secret|password|credential)\\s*[:=]\\s*['\"]([A-Za-z0-9+/=]{32,})['\"]".r
    cpg.literal
      .filter(l => longSecret.findFirstIn(l.code).isDefined)
      .filter(l => notLib(l.file.name.headOption))
      .filterNot(l => l.code.contains("process.env") || l.code.contains("getenv"))
      .l
      .foreach { l =>
        results += finding(
          title       = "Possible hardcoded high-entropy secret",
          severity    = "Medium",
          description =
            s"A long high-entropy string is assigned to a credential-like variable. " +
            s"Verify whether this is a real secret and externalise it if so. Code: ${l.code.take(80)}",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] generic Q4 high-entropy: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[generic] Done — $count finding(s) written to $outFile")
}
