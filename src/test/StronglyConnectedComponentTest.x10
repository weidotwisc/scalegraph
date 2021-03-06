/* 
 *  This file is part of the ScaleGraph project (https://sites.google.com/site/scalegraph/).
 * 
 *  This file is licensed to You under the Eclipse Public License (EPL);
 *  You may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *      http://www.opensource.org/licenses/eclipse-1.0.php
 * 
 *  (C) Copyright ScaleGraph Team 2011-2012.
 */

package test;

import org.scalegraph.test.AlgorithmTest;
import org.scalegraph.graph.Graph;
import org.scalegraph.io.NamedDistData;
import org.scalegraph.io.CSV;


final class StronglyConnectedComponentTest extends AlgorithmTest{	
	public static def main(args: Array[String](1)) {
		new StronglyConnectedComponentTest().execute(args);
	}
	
	public def run(args :Array[String](1), g :Graph): Boolean {
		val result = org.scalegraph.api.StronglyConnectedComponent.run(g);
		val dmc1 = result.dmc1;
		val dmc2 = result.dmc2;
		if(args(0).equals("write")) {
			CSV.write(args(1), new NamedDistData(["sccA" as String], [dmc1 as Any]), true);
			CSV.write(args(2), new NamedDistData(["sccB" as String], [dmc2 as Any]), true);
			return true;
		}
		else if(args(0).equals("check")) {
			var ok : Boolean = true;
			ok = checkResult(dmc1, args(1), 0L);
			if(!ok) return false;
			ok = checkResult(dmc2, args(2), 0L);
			if(!ok) return false;
			val numC = Long.parse(args(3));
			if(numC != result.cluster) return false;
			return true;
		}
		else {
			throw new IllegalArgumentException("Unknown command :" + args(0));
		}
	}
	
}