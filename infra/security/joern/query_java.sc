// Joern security query script — Java (also covers Kotlin via the Java CPG model).
//
// Usage:
//   joern --script query_java.sc \
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
  println(s"[java] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[java] Running Java security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — Runtime.exec / ProcessBuilder — command injection
  Try {
    cpg.call
      .filter(c => c.code.contains("Runtime.getRuntime().exec") ||
                   c.code.contains("Runtime.exec") ||
                   c.code.contains("new ProcessBuilder"))
      .l
      .foreach { c =>
        results += finding(
          title       = "Runtime.exec / ProcessBuilder — command injection risk",
          severity    = "High",
          description =
            s"Executing OS commands via Runtime.exec or ProcessBuilder with user-controlled " +
            s"input allows command injection. Sanitise all inputs, prefer allow-lists, or " +
            s"use safer abstractions. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q1 Runtime.exec: ${e.getMessage}"); case _ => }

  // Q2 — SQL injection via string concatenation in query methods
  Try {
    cpg.call
      .filter(c =>
        (c.name.matches("(?i).*execute.*|.*prepareStatement.*|.*createQuery.*|.*createNativeQuery.*")
        || c.code.contains(".executeQuery") || c.code.contains(".executeUpdate"))
        && (c.code.contains(" + ") || c.code.contains("String.format") || c.code.contains("concat("))
      )
      .l
      .foreach { c =>
        results += finding(
          title       = "SQL injection — string-concatenated query",
          severity    = "Critical",
          description =
            s"A database query appears to be built by string concatenation. Use parameterised " +
            s"PreparedStatements or ORM named parameters to prevent SQL injection. " +
            s"Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q2 SQL injection: ${e.getMessage}"); case _ => }

  // Q3 — ObjectInputStream.readObject — insecure Java deserialization
  Try {
    cpg.call
      .filter(c => c.code.contains("ObjectInputStream") || c.code.contains("readObject(") ||
                   c.code.contains("readUnshared("))
      .l
      .foreach { c =>
        results += finding(
          title       = "ObjectInputStream.readObject — unsafe deserialization",
          severity    = "Critical",
          description =
            s"Deserialising Java objects from untrusted streams via ObjectInputStream allows " +
            s"Remote Code Execution. Use a JSON/XML library or implement a resolveClass " +
            s"whitelist. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q3 deserialization: ${e.getMessage}"); case _ => }

  // Q4 — XXE: XMLInputFactory / DocumentBuilderFactory without disabling external entities
  Try {
    cpg.call
      .filter(c => (c.code.contains("XMLInputFactory.newInstance") ||
                    c.code.contains("DocumentBuilderFactory.newInstance") ||
                    c.code.contains("SAXParserFactory.newInstance"))
                && !c.code.contains("IS_SUPPORTING_EXTERNAL_ENTITIES")
                && !c.code.contains("FEATURE_SECURE_PROCESSING"))
      .l
      .foreach { c =>
        results += finding(
          title       = "XML parser without XXE protection",
          severity    = "High",
          description =
            s"An XML parser factory is instantiated without explicitly disabling external entity " +
            s"processing. Set XMLInputFactory.IS_SUPPORTING_EXTERNAL_ENTITIES to false or enable " +
            s"FEATURE_SECURE_PROCESSING. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q4 XXE: ${e.getMessage}"); case _ => }

  // Q5 — Path traversal: new File() / Paths.get() with user-controlled concatenation
  Try {
    cpg.call
      .filter(c => (c.code.contains("new File(") || c.code.contains("Paths.get(")) &&
                   (c.code.contains(" + ") || c.code.contains("concat(")))
      .l
      .foreach { c =>
        results += finding(
          title       = "Path traversal — user input in file path",
          severity    = "High",
          description =
            s"A file path is constructed by concatenation, which may allow path traversal " +
            s"(../../etc/passwd). Canonicalise the path and verify it stays within the " +
            s"intended base directory. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q5 path traversal: ${e.getMessage}"); case _ => }

  // Q6 — Weak cryptography: MD5 / SHA1 / DES / RC4
  Try {
    cpg.call
      .filter(c =>
        c.code.contains("MessageDigest.getInstance") ||
        c.code.contains("Cipher.getInstance") ||
        c.code.contains("KeyGenerator.getInstance")
      )
      .filter(c =>
        c.code.toUpperCase.contains("\"MD5\"") || c.code.toUpperCase.contains("\"SHA-1\"") ||
        c.code.toUpperCase.contains("\"SHA1\"") || c.code.toUpperCase.contains("\"DES\"") ||
        c.code.toUpperCase.contains("\"RC4\"") || c.code.toUpperCase.contains("\"RC2\"")
      )
      .l
      .foreach { c =>
        results += finding(
          title       = "Weak cryptographic algorithm",
          severity    = "Medium",
          description =
            s"A weak or broken cryptographic algorithm (MD5, SHA-1, DES, RC4) is used. " +
            s"Use SHA-256/SHA-3 for hashing and AES-256-GCM for encryption. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q6 weak crypto: ${e.getMessage}"); case _ => }

  // Q7 — Hardcoded credentials in literals
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\\s*=\\s*\"([^\"]{6,})\"".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("System.getenv") || l.code.contains("System.getProperty"))
      .l
      .foreach { l =>
        results += finding(
          title       = "Hardcoded credential in Java source",
          severity    = "High",
          description =
            s"A string literal appears to assign a credential. Load secrets from environment " +
            s"variables or a vault at runtime. Code: ${l.code.take(80)}",
          filePath = l.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = l.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q7 secrets: ${e.getMessage}"); case _ => }

  // Q8 — Insecure random (java.util.Random for security-sensitive use)
  Try {
    cpg.call
      .filter(c => c.code.contains("new Random()") || c.code.contains("Math.random()"))
      .l
      .foreach { c =>
        results += finding(
          title       = "Insecure random number generator",
          severity    = "Medium",
          description =
            s"java.util.Random and Math.random() are not cryptographically secure. " +
            s"Use java.security.SecureRandom for tokens, nonces, or keys. Code: ${c.code.take(120)}",
          filePath = c.file.name.headOption.map(cleanPath).getOrElse(""),
          line     = c.lineNumber.getOrElse(0)
        )
      }
  } match { case Failure(e) => println(s"[WARN] java Q8 insecure random: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[java] Done — $count finding(s) written to $outFile")
}
