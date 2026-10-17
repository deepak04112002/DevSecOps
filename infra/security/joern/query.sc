// Illustrative Joern query.
// Validate the API and query syntax against your pinned Joern version.

import io.shiftleft.semanticcpg.language._

@main def exec(): Unit = {
  println("=== Joern Code Property Graph Analysis ===")

  println("Method count: " + cpg.method.size)

  println("=== Discovered method names ===")
  cpg.method.name.l.foreach(println)
}