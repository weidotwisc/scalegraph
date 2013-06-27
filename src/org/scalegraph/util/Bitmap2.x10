package org.scalegraph.util;

import x10.util.IndexedMemoryChunk;
import x10.compiler.Native;
import x10.util.concurrent.AtomicLong;
import x10.compiler.Ifndef;
import x10.compiler.Inline;


/**
 * Bitmap used to implement queue for saving space and parallizing 
 */
public struct Bitmap2 {
    private val bitLength: Long;
    private val data: IndexedMemoryChunk[Long];
    private val bitPerWord = 64;
    private val setCount: AtomicLong;
    private val semaphore: IndexedMemoryChunk[Long];
    
    public def this(length: Long) {
        bitLength = length;
        val allocSize = (bitLength >> 6) + (((bitLength & 63L) > 0L)? 1 : 0); // div by 64
        data = IndexedMemoryChunk.allocateZeroed[Long](allocSize, 64, false);
        semaphore = IndexedMemoryChunk.allocateZeroed[Long](allocSize, 64, false);
        setCount = new AtomicLong(0);
    }
    
    @Native("c++", "__sync_bool_compare_and_swap((#imc)->raw() + #index, #oldVal, #newVal)")
    private static native def compare_and_swap[T](imc: IndexedMemoryChunk[T], index: Long, oldVal: T, newVal: T): Boolean;
    
    @Inline
    private def acquireLock(word: Long) {
        while (true) {
            // non-blocking mutual exclusion
            // increase semaphore
            if (compare_and_swap[Long](semaphore, word, 0, 1)) {
                break;
            }
        }
    }
    
    @Inline
    private def releaseLock(word: Long) {
        while(true){
            if(compare_and_swap[Long](semaphore, word, 1, 0))
                break;
        }
    }
    
    public def set(bit: Long) {
        val bitOffset = bit & ((1L << 6) -1);
        val wordOffset = bit >> 6;
        val mask = (1L << (bitOffset as Int));
        @Ifndef("NO_BOUNDS_CHECKS") {
            if(bit < 0 || bit >= bitLength)
                throw new ArrayIndexOutOfBoundsException("bit (" + bit + ") not contained in BitMap");
        }
        // If it is already set
        if (((data(wordOffset) as ULong) & (mask as ULong)) > 0UL)
            throw new Exception("Bit (" + bit + ") is already set");
        acquireLock(wordOffset);
        data(wordOffset) = data(wordOffset) | mask;
        releaseLock(wordOffset);
        
        setCount.incrementAndGet();
    }
    
    public def clear(bit: Long) {
        val bitOffset = bit & ((1L << 6) -1);
        val wordOffset = bit >> 6;
        val mask = ~(1L << (bitOffset as Int));
        @Ifndef("NO_BOUNDS_CHECKS") {
            if(bit < 0 || bit >= bitLength)
                throw new ArrayIndexOutOfBoundsException("bit (" + bit + ") not contained in BitMap");
        }
        // If it is already clear
        if ((data(wordOffset) | mask) == 0L)
            throw new Exception("Bit is already cleared");
        acquireLock(wordOffset);
        data(wordOffset) = data(wordOffset) & mask;
        releaseLock(wordOffset);

        setCount.decrementAndGet();
    }
    
    public def isSet(bit: Long) = !isNotSet(bit);
    
    public def isNotSet(bit: Long): Boolean {
        val bitOffset = bit & ((1L << 6) -1);
        val wordOffset = bit >> 6;
        val mask = (1L << (bitOffset as Int));
        return ((data(wordOffset) as ULong) & (mask as ULong)) == 0UL;
    }
    
    public def isNotSetThenSet(bit :Long): Boolean {
        
        val bitOffset = bit & ((1L << 6) -1);
        val wordOffset = bit >> 6;
        val mask = (1L << (bitOffset as Int));
        acquireLock(wordOffset);
        val ret = ((data(wordOffset) as ULong) & (mask as ULong)) == 0UL;
        
        // Set
        data(wordOffset) = data(wordOffset) | mask;
        releaseLock(wordOffset);
        
        return ret;
    }
    
    public def examine(callback: (i: Long, threadId: Int) => void) {
        val f = (threadId: Long, r: LongRange) => {
            for (w in r) {
                val word = data(w);
                var mask: Long = 0x1;
                if (word == 0L)
                    continue;
                for (var l: Long = 0; l < bitPerWord; ++l) { 
                    mask = 1L << (l as Int);
                    if (((word as ULong) & (mask as ULong)) > 0UL) {
                        val bitPos = w * bitPerWord + l;	                    
                        if (bitPos >= bitLength)
                            break;	                    
                        callback(bitPos , threadId as Int);
                    } 
                }
            }
        };
        if (setCount.longValue() > 0)
            Parallel.iter(0..(data.length() as Long - 1), f);
    }
    
    public def clearAll() {   
        data.clear(0, data.length());
        setCount.set(0L);
    }
    
    public def setBitCount() = setCount.longValue();
}