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

package org.scalegraph.util.tuple;
public final struct Tuple3 [T1,T2,T3] {
    public val1: T1;
    public val2: T2;
    public val3: T3;

    public def this(val1: T1, val2: T2, val3: T3) {
        this.val1 = val1;
        this.val2 = val2;
        this.val3 = val3;
    }

    public def get1() = val1;
    public def get2() = val2;
    public def get3() = val3;

    public def toString() : String {
        return ("Tuple3("+val1+","+val2+","+val3+")");
    }

}
