// Joern security query script — Ruby.
//
// Usage:
//   joern --script query_ruby.sc \
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
  println(s"[ruby] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[ruby] Running Ruby security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — eval() / instance_eval / class_eval / module_eval — code injection
  Try {
    cpg.call
      .filter(c => c.name == "eval" || c.name == "instance_eval" ||
                   c.name == "class_eval"  || c.name == "module_eval")
      .l.foreach { c =>
        results += finding(s"${c.name}() — code injection risk", "Critical",
          s"${c.name}() executes arbitrary Ruby code. If user input reaches this call " +
          s"the application is fully compromised. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q1: ${e.getMessage}"); case _ => }

  // Q2 — system / exec / `backtick` / Open3 — command injection
  Try {
    cpg.call
      .filter(c => Seq("system","exec","spawn","popen","IO.popen","Open3.capture2")
                     .exists(fn => c.name == fn || c.code.contains(s"$fn(")))
      .filter(c => c.code.contains(" + ") || c.code.contains("\"#{") || c.code.contains("'#{"))
      .l.foreach { c =>
        results += finding("OS command execution with interpolation — command injection", "High",
          s"A shell command is built with string interpolation. User-controlled input in " +
          s"the interpolated value enables command injection. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q2: ${e.getMessage}"); case _ => }

  // Q3 — SQL injection via string interpolation in ActiveRecord / raw SQL
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains(".where(") || c.code.contains(".find_by_sql(") ||
         c.code.contains(".execute(") || c.code.contains(".select("))
        && (c.code.contains("\"#{") || c.code.contains("'#{") || c.code.contains(" + "))
      )
      .l.foreach { c =>
        results += finding("SQL injection — interpolated ActiveRecord query", "Critical",
          s"User input is interpolated directly into a SQL query. Use parameterised " +
          s"queries: .where('col = ?', value). Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q3: ${e.getMessage}"); case _ => }

  // Q4 — YAML.load (unsafe deserialization in older Ruby/Psych)
  Try {
    cpg.call
      .filter(c => c.code.contains("YAML.load(") && !c.code.contains("YAML.safe_load"))
      .l.foreach { c =>
        results += finding("YAML.load — unsafe deserialization", "High",
          s"YAML.load can deserialise arbitrary Ruby objects from untrusted input. " +
          s"Use YAML.safe_load or Psych.safe_load instead. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q4: ${e.getMessage}"); case _ => }

  // Q5 — Mass assignment without strong parameters (Rails)
  Try {
    cpg.call
      .filter(c => c.code.contains(".update(params)") || c.code.contains(".update_attributes(params)") ||
                   c.code.contains(".new(params)") || c.code.contains(".create(params)"))
      .l.foreach { c =>
        results += finding("Mass assignment without strong parameters", "Medium",
          s"Passing raw params to a model allows attackers to set arbitrary attributes. " +
          s"Use params.require(:model).permit(:field1, :field2). Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q5: ${e.getMessage}"); case _ => }

  // Q6 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\\s*=\\s*['\"]([^'\"]{6,})['\"]".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("ENV[") || l.code.contains("ENV.fetch"))
      .l.foreach { l =>
        results += finding("Hardcoded credential in Ruby source", "High",
          s"Load secrets from ENV or Rails credentials instead. Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] ruby Q6: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[ruby] Done — $count finding(s) written to $outFile")
}
