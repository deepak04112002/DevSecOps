// Joern security query script — C and C++ (both use the 'c' / 'newc' CPG).
//
// Usage:
//   joern --script query_c.sc \
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
  println(s"[c/c++] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[c/c++] Running C/C++ security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — Dangerous buffer functions: gets, strcpy, strcat, sprintf, scanf
  Try {
    val dangerousFns = Seq("gets","strcpy","strcat","sprintf","vsprintf","scanf","sscanf","fscanf")
    cpg.call
      .filter(c => dangerousFns.contains(c.name))
      .l.foreach { c =>
        results += finding(s"${c.name}() — buffer overflow risk", "High",
          s"${c.name}() does not check buffer length and can cause a buffer overflow. " +
          s"Use the bounded variant: fgets, strncpy, strncat, snprintf, or fgets. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q1: ${e.getMessage}"); case _ => }

  // Q2 — system() / popen() — command injection
  Try {
    cpg.call
      .filter(c => c.name == "system" || c.name == "popen" || c.name == "execl" ||
                   c.name == "execv" || c.name == "execvp")
      .l.foreach { c =>
        results += finding(s"${c.name}() — command injection risk", "High",
          s"${c.name}() executes a shell command. If the argument includes user input " +
          s"without sanitisation, command injection is possible. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q2: ${e.getMessage}"); case _ => }

  // Q3 — printf / fprintf format-string vulnerability
  Try {
    cpg.call
      .filter(c => (c.name == "printf" || c.name == "fprintf" || c.name == "syslog") &&
                    c.argument.size == 1)   // single non-format arg = potential user-controlled format
      .l.foreach { c =>
        results += finding("printf with non-constant format string — format string vulnerability", "High",
          s"Passing a user-controlled string as printf format allows reading stack memory or " +
          s"arbitrary writes. Always use printf(\"%s\", user_input). Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q3: ${e.getMessage}"); case _ => }

  // Q4 — malloc without NULL check (potential null-dereference)
  Try {
    cpg.call
      .nameExact("malloc", "calloc", "realloc")
      .l.foreach { c =>
        results += finding("malloc/calloc without return-value check", "Low",
          s"The return value of ${c.name}() is not checked for NULL. A failed allocation " +
          s"followed by a dereference causes a crash or undefined behaviour. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q4: ${e.getMessage}"); case _ => }

  // Q5 — Integer overflow in size argument to allocation functions
  Try {
    cpg.call
      .filter(c => (c.name == "malloc" || c.name == "calloc") &&
                   (c.code.contains(" * ") || c.code.contains(" + ")))
      .l.foreach { c =>
        results += finding("Potential integer overflow in allocation size", "Medium",
          s"The size argument to ${c.name}() involves arithmetic that may overflow, " +
          s"causing an undersized allocation and subsequent buffer overflow. " +
          s"Validate sizes before allocating. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q5: ${e.getMessage}"); case _ => }

  // Q6 — Hardcoded credentials in string literals
  Try {
    val credPattern =
      "(?i)(password|secret|api_key|token)\\s*=\\s*\"([^\"]{6,})\"".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .l.foreach { l =>
        results += finding("Hardcoded credential in C/C++ source", "High",
          s"Load secrets from environment variables or a config file outside the repo. " +
          s"Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] c Q6: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[c/c++] Done — $count finding(s) written to $outFile")
}
