// Joern security query script — Python.
//
// Usage:
//   joern --script query_python.sc \
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
  println(s"[python] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[python] Running Python security queries...")

  val results = collection.mutable.ListBuffer[String]()
  val notLib  = (name: Option[String]) =>
    !name.exists(n => n.contains("site-packages") || n.contains("dist-packages"))

  // Q1 — eval() / exec()
  Try {
    cpg.call
      .nameExact("eval", "exec")
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = s"Use of ${c.name}() — code injection risk",
          severity    = "High",
          description =
            s"${c.name}() executes arbitrary Python code. If user-controlled data reaches " +
            s"this call it allows full code injection. Use ast.literal_eval for safe evaluation " +
            s"of literals. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q1 eval/exec: ${e.getMessage}"); case _ => }

  // Q2 — os.system / os.popen — command injection
  Try {
    cpg.call
      .filter(c => c.code.contains("os.system") || c.code.contains("os.popen") ||
                   c.code.contains("os.execv") || c.code.contains("os.execl"))
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "os.system / os.popen — command injection risk",
          severity    = "High",
          description =
            s"os.system/os.popen pass a shell command string directly. If user input is included " +
            s"without sanitisation, command injection is possible. Use subprocess with a list argument " +
            s"and shell=False instead. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q2 os.system: ${e.getMessage}"); case _ => }

  // Q3 — subprocess with shell=True
  Try {
    cpg.call
      .filter(c => (c.code.contains("subprocess.call") || c.code.contains("subprocess.run") ||
                    c.code.contains("subprocess.Popen") || c.code.contains("subprocess.check_output"))
                && c.code.contains("shell=True"))
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "subprocess with shell=True — command injection risk",
          severity    = "High",
          description =
            s"subprocess called with shell=True interprets the command through the shell, " +
            s"enabling injection if any part of the command is user-controlled. " +
            s"Use shell=False with a list. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q3 subprocess shell=True: ${e.getMessage}"); case _ => }

  // Q4 — pickle.loads / pickle.load — arbitrary code via deserialization
  Try {
    cpg.call
      .filter(c => c.code.contains("pickle.loads") || c.code.contains("pickle.load") ||
                   c.code.contains("cPickle.loads") || c.code.contains("cPickle.load"))
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "pickle.load(s) — unsafe deserialization",
          severity    = "Critical",
          description =
            s"Deserialising pickle data from untrusted sources allows arbitrary code execution. " +
            s"Use JSON, msgpack, or another safe format for untrusted data. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q4 pickle: ${e.getMessage}"); case _ => }

  // Q5 — SQL injection via string concatenation / %-formatting in queries
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains(".execute(") || c.code.contains(".executemany("))
        && (c.code.contains(" + ") || c.code.contains(" % ") ||
            c.code.contains(".format(") || c.code.contains("f\"") || c.code.contains("f'"))
      )
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "SQL injection — string-concatenated query",
          severity    = "Critical",
          description =
            s"A database .execute() call appears to build the SQL string by concatenation or " +
            s"string formatting. Use parameterised queries (cursor.execute(sql, params)) " +
            s"to prevent SQL injection. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q5 SQL injection: ${e.getMessage}"); case _ => }

  // Q6 — yaml.load without Loader (unsafe YAML deserialization)
  Try {
    cpg.call
      .filter(c => c.code.contains("yaml.load") && !c.code.contains("Loader="))
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "yaml.load() without Loader — unsafe deserialization",
          severity    = "High",
          description =
            s"yaml.load() without an explicit Loader can deserialise arbitrary Python objects. " +
            s"Use yaml.safe_load() or pass Loader=yaml.SafeLoader. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q6 yaml.load: ${e.getMessage}"); case _ => }

  // Q7 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|password|passwd|auth[_-]?token)\\s*=\\s*['\"]([^'\"]{6,})['\"]".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filter(l => notLib(l.file.name.headOption))
      .filterNot(l => l.code.contains("os.environ") || l.code.contains("getenv"))
      .l
      .foreach { l =>
        results += finding(
          title       = "Hardcoded credential in Python source",
          severity    = "High",
          description =
            s"A literal appears to assign a credential. Load secrets from environment variables " +
            s"or a secrets manager instead. Code: ${l.code.take(80)}",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q7 secrets: ${e.getMessage}"); case _ => }

  // Q8 — assert used for security checks (stripped in optimised builds)
  Try {
    cpg.call
      .nameExact("assert")
      .filter(c => c.code.toLowerCase.matches(".*assert.*(auth|permission|role|admin|login|is_staff|is_admin).*"))
      .filter(c => notLib(c.file.name.headOption))
      .l
      .foreach { c =>
        results += finding(
          title       = "assert used for security/auth check",
          severity    = "Medium",
          description =
            s"assert statements are removed when Python runs with -O optimisation. " +
            s"Never rely on assert for authentication or authorisation checks. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] python Q8 assert-auth: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[python] Done — $count finding(s) written to $outFile")
}
