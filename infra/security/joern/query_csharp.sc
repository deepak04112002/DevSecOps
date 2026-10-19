// Joern security query script — C#.
//
// Usage:
//   joern --script query_csharp.sc \
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
  println(s"[csharp] Loading CPG: $cpgFile")
  importCpg(cpgFile)
  println("[csharp] Running C# security queries...")

  val results = collection.mutable.ListBuffer[String]()

  // Q1 — SQL injection via string interpolation / concatenation
  Try {
    cpg.call
      .filter(c =>
        (c.code.contains("SqlCommand") || c.code.contains("ExecuteNonQuery") ||
         c.code.contains("ExecuteReader") || c.code.contains("ExecuteScalar") ||
         c.code.contains("SqlDataAdapter"))
        && (c.code.contains(" + ") || c.code.contains("String.Format") ||
            c.code.contains("$\"") || c.code.contains("string.Concat"))
      )
      .l.foreach { c =>
        results += finding("SQL injection — dynamic query construction", "Critical",
          s"A SQL command is built by string concatenation or interpolation. " +
          s"Use SqlCommand with SqlParameter instead. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q1: ${e.getMessage}"); case _ => }

  // Q2 — Process.Start with user input — command injection
  Try {
    cpg.call
      .filter(c => c.code.contains("Process.Start") &&
                   (c.code.contains(" + ") || c.code.contains("String.Format") || c.code.contains("$\"")))
      .l.foreach { c =>
        results += finding("Process.Start — command injection risk", "High",
          s"Process.Start with dynamic arguments may allow command injection if input is user-controlled. " +
          s"Use a fixed executable name and pass inputs as separate validated arguments. " +
          s"Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q2: ${e.getMessage}"); case _ => }

  // Q3 — BinaryFormatter / NetDataContractSerializer (unsafe deserialization)
  Try {
    cpg.call
      .filter(c => c.code.contains("BinaryFormatter") || c.code.contains("NetDataContractSerializer") ||
                   c.code.contains("ObjectStateFormatter") || c.code.contains("LosFormatter"))
      .l.foreach { c =>
        results += finding("Unsafe .NET deserialization", "Critical",
          s"BinaryFormatter and similar formatters are vulnerable to RCE when deserialising " +
          s"untrusted data. Use System.Text.Json or a type-safe serialiser. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q3: ${e.getMessage}"); case _ => }

  // Q4 — XmlDocument / XmlTextReader without disabling DTD processing (XXE)
  Try {
    cpg.call
      .filter(c => c.code.contains("XmlDocument") || c.code.contains("XmlTextReader") ||
                   c.code.contains("XPathDocument"))
      .filterNot(c => c.code.contains("DtdProcessing.Prohibit") ||
                      c.code.contains("ProhibitDtd = true"))
      .l.foreach { c =>
        results += finding("XML parser without XXE protection", "High",
          s"XmlDocument/XmlTextReader may process external entities (XXE). Set " +
          s"XmlReaderSettings.DtdProcessing = DtdProcessing.Prohibit. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q4: ${e.getMessage}"); case _ => }

  // Q5 — Weak hash: MD5 / SHA1
  Try {
    cpg.call
      .filter(c => c.code.contains("MD5.Create()") || c.code.contains("new MD5CryptoServiceProvider") ||
                   c.code.contains("SHA1.Create()") || c.code.contains("new SHA1Managed") ||
                   c.code.contains("new SHA1CryptoServiceProvider"))
      .l.foreach { c =>
        results += finding("Weak cryptographic hash (MD5/SHA1)", "Medium",
          s"MD5 and SHA-1 are cryptographically broken. Use SHA-256 or SHA-3 " +
          s"(System.Security.Cryptography.SHA256). Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q5: ${e.getMessage}"); case _ => }

  // Q6 — Random instead of RNGCryptoServiceProvider
  Try {
    cpg.call
      .filter(c => c.code.contains("new Random(") || c.code.contains("new Random()"))
      .l.foreach { c =>
        results += finding("System.Random — not cryptographically secure", "Medium",
          s"System.Random is not suitable for security-sensitive values. " +
          s"Use RandomNumberGenerator (RNGCryptoServiceProvider) instead. Code: ${c.code.take(120)}",
          c.file.name.headOption.map(cleanPath).getOrElse(""), c.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q6: ${e.getMessage}"); case _ => }

  // Q7 — Hardcoded secrets
  Try {
    val credPattern =
      "(?i)(password|secret|api[_-]?key|connectionstring|token)\\s*=\\s*\"([^\"]{6,})\"".r
    cpg.literal
      .filter(l => credPattern.findFirstIn(l.code).isDefined)
      .filterNot(l => l.code.contains("Environment.GetEnvironmentVariable") ||
                      l.code.contains("Configuration["))
      .l.foreach { l =>
        results += finding("Hardcoded credential in C# source", "High",
          s"Load secrets from environment variables, Azure Key Vault, or ASP.NET Core secrets. " +
          s"Code: ${l.code.take(80)}",
          l.file.name.headOption.map(cleanPath).getOrElse(""), l.lineNumber.getOrElse(0))
      }
  } match { case Failure(e) => println(s"[WARN] csharp Q7: ${e.getMessage}"); case _ => }

  val count = results.size
  writeResults(outFile, results.toList)
  println(s"[csharp] Done — $count finding(s) written to $outFile")
}
