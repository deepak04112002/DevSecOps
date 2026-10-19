// Joern security query script — Kotlin.
// Kotlin CPGs share the Java CPG model, so Java-style traversals work here too.
//
// Usage:
//   joern --script query_kotlin.sc \
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
  println(s"[kotlin] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[kotlin] Running Kotlin security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — Runtime.exec / ProcessBuilder — command injection
  Try {
    cpg.call
      .filter(c => c.code.contains("Runtime.getRuntime().exec") ||
                   c.code.contains("ProcessBuilder("))
      .l.foreach { c =>
        results += finding("Runtime.exec / ProcessBuilder — command injection", "High",
          s"OS command execution with user-controlled input allows command injection. " +
          s"Use a fixed command list and shell=false equivalent. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q1: ${e.getMessage}"); case _ => }

  // Q2 — SQL injection via string templates in queries
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains("execute(") || c.code.contains("executeQuery(") ||
         c.code.contains("createQuery(") || c.code.contains("rawQuery("))
        && (c.code.contains(" + ") || c.code.contains("\${") || c.code.contains("format(")))
      .l.foreach { c =>
        results += finding("SQL injection — dynamic query construction", "Critical",
          s"A database query is built using string interpolation or concatenation. " +
          s"Use parameterised queries or ORM abstractions. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q2: ${e.getMessage}"); case _ => }

  // Q3 — Unsafe deserialization via ObjectInputStream
  Try {
    cpg.call
      .filter(c => c.code.contains("ObjectInputStream") || c.code.contains("readObject("))
      .l.foreach { c =>
        results += finding("Unsafe Java/Kotlin deserialization", "Critical",
          s"ObjectInputStream.readObject() on untrusted data allows RCE. " +
          s"Use JSON/protobuf or a class-whitelisting ObjectInputStream. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q3: ${e.getMessage}"); case _ => }

  // Q4 — Weak cryptography
  Try {
    cpg.call
      .filter(c => c.code.contains("MessageDigest.getInstance") || c.code.contains("Cipher.getInstance"))
      .filter(c => c.code.toUpperCase.contains("\"MD5\"") || c.code.toUpperCase.contains("\"SHA-1\"") ||
                   c.code.toUpperCase.contains("\"DES\"") || c.code.toUpperCase.contains("\"RC4\""))
      .l.foreach { c =>
        results += finding("Weak cryptographic algorithm", "Medium",
          s"MD5, SHA-1, DES, or RC4 are cryptographically broken. Use SHA-256/AES-GCM. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q4: ${e.getMessage}"); case _ => }

  // Q5 — Insecure random
  Try {
    cpg.call
      .filter(c => c.code.contains("Random()") || c.code.contains("Math.random()") ||
                   c.code.contains("kotlin.random.Random"))
      .filterNot(c => c.code.contains("SecureRandom"))
      .l.foreach { c =>
        results += finding("Insecure random number generator", "Medium",
          s"kotlin.random.Random / java.util.Random are not cryptographically secure. " +
          s"Use java.security.SecureRandom for tokens, nonces, and keys. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q5: ${e.getMessage}"); case _ => }

  // Q6 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|access[_-]?token)\\s*=\\s*\"([^\"]{6,})\"".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("System.getenv") || l.code.contains("BuildConfig"))
      .l.foreach { l =>
        results += finding("Hardcoded credential in Kotlin source", "High",
          s"Load secrets from environment variables or a vault. Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] kotlin Q6: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[kotlin] Done — $count finding(s) written to $outFile")
}
