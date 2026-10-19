// Joern security query script — PHP.
//
// Usage:
//   joern --script query_php.sc \
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
  println(s"[php] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[php] Running PHP security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — eval()
  Try {
    cpg.call.nameExact("eval")
      .l.foreach { c =>
        results += finding("eval() — code injection", "Critical",
          s"eval() executes arbitrary PHP code. If user input reaches it the application " +
          s"is fully compromised. Remove eval() and redesign the logic. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q1: ${e.getMessage}"); case _ => }

  // Q2 — system / exec / passthru / shell_exec — command injection
  Try {
    cpg.call
      .filter(c => Seq("system","exec","passthru","shell_exec","popen","proc_open")
                     .exists(fn => c.name == fn || c.code.contains(s"$fn(")))
      .l.foreach { c =>
        results += finding("OS command execution — command injection risk", "High",
          s"${c.name}() passes a shell command string. User-controlled input enables command " +
          s"injection. Use escapeshellarg/escapeshellcmd, or avoid shell calls entirely. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q2: ${e.getMessage}"); case _ => }

  // Q3 — SQL injection: mysql_query / pg_query / mysqli_query with concatenation
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains("mysql_query") || c.code.contains("mysqli_query") ||
         c.code.contains("pg_query") || c.code.contains("sqlite_query") ||
         c.code.contains("->query(") || c.code.contains("->exec("))
        && (c.code.contains(" . ") || c.code.contains(" + ") || c.code.contains("\".$")))
      .l.foreach { c =>
        results += finding("SQL injection — string-concatenated query", "Critical",
          s"A database query is built by concatenation. Use PDO/mysqli prepared statements " +
          s"with bound parameters. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q3: ${e.getMessage}"); case _ => }

  // Q4 — include / require with user input (remote/local file inclusion)
  Try {
    cpg.call
      .filter(c =>
        (c.code.startsWith("include") || c.code.startsWith("require") ||
         c.code.startsWith("include_once") || c.code.startsWith("require_once"))
        && (c.code.contains("$_GET") || c.code.contains("$_POST") ||
            c.code.contains("$_REQUEST") || c.code.contains(" . "))
      )
      .l.foreach { c =>
        results += finding("File inclusion with user input — LFI/RFI risk", "Critical",
          s"include/require with user-controlled input allows Local or Remote File Inclusion. " +
          s"Use a whitelist of allowed file names. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q4: ${e.getMessage}"); case _ => }

  // Q5 — XSS: echo/print with user input and no htmlspecialchars
  Try {
    cpg.call
      .filter(c =>
        (c.code.startsWith("echo ") || c.code.startsWith("print ") || c.code.contains("echo("))
        && (c.code.contains("$_GET") || c.code.contains("$_POST") || c.code.contains("$_REQUEST"))
        && !c.code.contains("htmlspecialchars") && !c.code.contains("htmlentities")
      )
      .l.foreach { c =>
        results += finding("Reflected XSS — unescaped user input in output", "High",
          s"User-supplied data is printed directly without HTML encoding. " +
          s"Wrap output in htmlspecialchars(..., ENT_QUOTES, 'UTF-8'). Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q5: ${e.getMessage}"); case _ => }

  // Q6 — Weak hash: md5() / sha1() for passwords
  Try {
    cpg.call
      .filter(c => c.name == "md5" || c.name == "sha1")
      .l.foreach { c =>
        results += finding("Weak hash function (md5/sha1)", "Medium",
          s"md5() and sha1() are cryptographically broken for password storage. " +
          s"Use password_hash() with PASSWORD_BCRYPT or PASSWORD_ARGON2ID. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q6: ${e.getMessage}"); case _ => }

  // Q7 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|token)\\s*=\\s*['\"]([^'\"]{6,})['\"]".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("getenv") || l.code.contains("$_ENV"))
      .l.foreach { l =>
        results += finding("Hardcoded credential in PHP source", "High",
          s"Load secrets from environment variables or a vault. Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] php Q7: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[php] Done — $count finding(s) written to $outFile")
}
