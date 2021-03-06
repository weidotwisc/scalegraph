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

package org.scalegraph.xpregel;

import x10.compiler.Ifdef;

import org.scalegraph.Config;

import org.scalegraph.util.MemoryChunk;
import org.scalegraph.util.GrowableMemory;
import org.scalegraph.util.Bitmap;
import org.scalegraph.util.Algorithm;
import org.scalegraph.util.MathAppend;
import org.scalegraph.util.Parallel;
import org.scalegraph.util.Team2;
import org.scalegraph.graph.id.IdStruct;
import org.scalegraph.graph.id.OnedC;

final struct MessageBuffer[M] { M haszero } {
	val messages :GrowableMemory[M] = new GrowableMemory[M]();
	val dstIds :GrowableMemory[Long] = new GrowableMemory[Long]();
	
	def this() { }
}

final class MessageCommunicator[M] { M haszero } {
	private static type XP = org.scalegraph.id.ProfilingID.XPregel; 
	/* Name form
	 * UC : UniCast message
	 * BC : BroadCast message
	 * xxC : buffer for Compute phase
	 * xxS : send buffer
	 * xxR : receive buffer
	 */
	val mTeam :Team2;
	val mIds :IdStruct;
	val mNumThreads :Int;
	var mSuperstep :Int;

	val mVtoD :OnedC.VtoD;
	val mDtoV :OnedC.DtoV;
	val mDtoS :OnedC.DtoS;
	val mStoD :OnedC.StoD;
	val mStoV :OnedC.StoV;

	var mInEdgesOffset :MemoryChunk[Long];
	var mInEdgesVertex :MemoryChunk[Long];
	var mInEdgesMask :Bitmap;

	var mUCREnabled :Boolean;
	var mBCREnabled :Boolean;
	
	var mUCCMessages :MemoryChunk[MessageBuffer[M]];
	
	var mBCCHasMessage :Bitmap;
	var mBCCMessages :MemoryChunk[M];
	
	var mUCSRawMessageCount :Long;
	var mUCSCount :MemoryChunk[Int];
	var mUCSOffset :MemoryChunk[Int];
	var mUCSIds :MemoryChunk[Long];
	var mUCSMessages :MemoryChunk[M];
	
	var mBCSInputCount :Long;
	var mBCSCount :MemoryChunk[Int];
	var mBCSOffset :MemoryChunk[Int];
	var mBCSMessages :MemoryChunk[M];
	var mBCSMask :Bitmap;
	
	var mUCRMessages :MemoryChunk[M];
	var mUCROffset :MemoryChunk[Long];
	
	var mBCRHasMessage :Bitmap;
	var mBCROffset :MemoryChunk[Long];
	var mBCRMessages :MemoryChunk[M];
	
	var mNumActiveVertexes :Long;
	
	def this(team :Team2, ids :IdStruct, numThreads :Int)
	{
		val rank_c = team.base.role()(0);
		mTeam = team;
		mIds = ids;
		mNumThreads = numThreads;
		mSuperstep = 0;
		mVtoD = new OnedC.VtoD(ids);
		mDtoV = new OnedC.DtoV(ids);
		mDtoS = new OnedC.DtoS(ids);
		mStoD = new OnedC.StoD(ids, rank_c);
		mStoV = new OnedC.StoV(ids, rank_c);

		// TODO: optimize
		mUCCMessages = new MemoryChunk[MessageBuffer[M]](mNumThreads * mTeam.size(),
				(i:Long) => new MessageBuffer[M]());
		mBCCHasMessage = new Bitmap(mIds.numberOfLocalVertexes(), false);
		mBCCMessages = new MemoryChunk[M](mIds.numberOfLocalVertexes());
	}
	
	def del() {
		// TODO:
	}
	
	def messageBuffer(tid :Long) = mUCCMessages.subpart(tid * mTeam.size(), mTeam.size());
	
	def message(srcid :Long, buffer :GrowableMemory[M]) {
		if(mUCREnabled) {
			// unicast messages
			if(mUCROffset.size() == 0L)
				return new MemoryChunk[M](0);
			
			val start = mUCROffset(srcid);
			val length = mUCROffset(srcid + 1) - start;
			return mUCRMessages.subpart(start, length);
		}
		else if(mBCREnabled) {
			// broadcast messages
			val bmp = mBCRHasMessage;
			val offset = mBCROffset;
			val mes = mBCRMessages;
			val start = mInEdgesOffset(srcid);
			val end = mInEdgesOffset(srcid + 1);
			val length = end - start;
			
			buffer.setSize(0);
			for(i in 0..(length-1)) {
				val dst = mInEdgesVertex(start + i);
				
				if(bmp(dst)) { // TODO: optimize
					val wordOffset = Bitmap.offset(dst);
					val wordMask = Bitmap.mask(dst) - 1;
					val mesOffset = offset(wordOffset) +
						MathAppend.popcount(bmp.word(wordOffset) & wordMask);
					buffer.add(mes(mesOffset));
				}
			}
			
			return buffer.raw();
		}
		return new MemoryChunk[M]();
	}
	
	def sqweezeMessage[V, E, A](ctx :VertexContext[V, E, M, A]) { M haszero, A haszero } {
		mNumActiveVertexes += ctx.mNumActiveVertexes; ctx.mNumActiveVertexes = 0L;
		mBCSInputCount += ctx.mBCSInputCount; ctx.mBCSInputCount = 0L;
	}
	
	private def processUnicastMessages(combine : (MemoryChunk[M]) => M) {
		val numPlaces = mTeam.size();
		val combineEnabled = (combine != null);
		val nullMessage = Zero.get[M]();
		val numMessages = mUCSRawMessageCount;
		
		mUCSCount = new MemoryChunk[Int](numPlaces);
		mUCSOffset = new MemoryChunk[Int](numPlaces + 1);
		val mesCount :MemoryChunk[Int];
		val mesOffset :MemoryChunk[Int];
		if(combineEnabled) {
			mesCount = new MemoryChunk[Int](numPlaces);
			mesOffset = new MemoryChunk[Int](numPlaces + 1);
		}
		else {
			mesCount = mUCSCount;
			mesOffset = mUCSOffset;
		}
		mesOffset(0) = 0;
		for(p in 0..(numPlaces-1)) mesCount(p) = 0;

		// count number of messages
		for(th in 0..(mNumThreads-1)) {
			for(p in 0..(numPlaces-1)) {
				mesCount(p) += mUCCMessages(th * numPlaces + p).messages.size() as Int;
			}
		}
		for(p in 0..(numPlaces-1)) {
			mesOffset(p + 1) = mesOffset(p) + mesCount(p);
		}
		
		assert (numMessages == mesOffset(numPlaces) as Long);

		val idsTmp = new MemoryChunk[Long](numMessages);
		Parallel.iter(0L..(numPlaces-1), (p :Long) => {
			val pstart = mesOffset(p);
			val plength = mesOffset(p+1) - pstart;
			val idsLocal = idsTmp.subpart(pstart, plength);
			var offset :Long = 0;
			for(th in 0..(mNumThreads-1)) {
				val src = mUCCMessages(th * numPlaces + p);
				val size = src.dstIds.size();
				MemoryChunk.copy(src.dstIds.raw(), 0L, idsLocal, offset, size);
			//	src.dstIds.copyTo(idsLocal.subpart(offset, size), 0L, size);
				offset += size;
			}
		});
		for(i in mUCCMessages.range()) mUCCMessages(i).dstIds.del();
		
		val mesTmp = new MemoryChunk[M](numMessages);
		Parallel.iter(0L..(numPlaces-1), (p :Long) => {
			val pstart = mesOffset(p);
			val plength = mesOffset(p+1) - pstart;
			val mesLocal = mesTmp.subpart(pstart, plength);
			var offset :Long = 0;
			for(th in 0..(mNumThreads-1)) {
				val src = mUCCMessages(th * numPlaces + p);
				val size = src.messages.size();
				MemoryChunk.copy(src.messages.raw(), 0L, mesLocal, offset, size);
				//src.messages.copyTo(mesLocal.subpart(offset, size), 0L, size);
				offset += size;
			}
		});
		for(i in mUCCMessages.range()) mUCCMessages(i).messages.del();

		if(combine != null) {
			Parallel.iter(0L..(numPlaces-1), (p :Long) => {
				val pstart = mesOffset(p);
				val plength = mesOffset(p+1) - pstart;
				if(plength == 0) return ; // short cut
				
				val mesLocal = mesTmp.subpart(pstart, plength);
				val idsLocal = idsTmp.subpart(pstart, plength);
				
				// sort
				Algorithm.sort(idsLocal, mesLocal);
				
				// combine
				var resultLength: Int = 0;
				var start: Long = 0;
				var length: Long = 1;
				var vid: Long = idsLocal(0);
				for(i in (1L..(idsLocal.size()-1))) {
					if(vid == idsLocal(i)) {
						++length;
					}
					else {
						if(length > 1) {
							mesLocal(resultLength) = combine(mesLocal.subpart(start, length));
						}
						else {
							assert (length == 1L);
							mesLocal(resultLength) = mesLocal(start);
						}
						idsLocal(resultLength++) = vid;
						start = i;
						length = 1;
						vid = idsLocal(i);
					}
				}
				if(length > 1) {
					mesLocal(resultLength) = combine(mesLocal.subpart(start, length));
				}
				else {
					assert (length == 1L);
					mesLocal(resultLength) = mesLocal(start);
				}
				idsLocal(resultLength++) = vid;
				mUCSCount(p) = resultLength;
			});
		}

		val numCombinedMessages :Long;
		if(combine != null) {
			// compact
			for(p in 0..(numPlaces-1)) {
				mUCSOffset(p + 1) = mUCSOffset(p) + mUCSCount(p);
			}
			numCombinedMessages = mUCSOffset(numPlaces);

			mUCSIds = new MemoryChunk[Long](numCombinedMessages);
			mUCSMessages = new MemoryChunk[M](numCombinedMessages);
			val idsBuffer = mUCSIds;
			val mesBuffer = mUCSMessages;
			
			Parallel.iter(0..(numPlaces-1), (p :Int) => {
				val tmpOffset = mesOffset(p) as Long;
				val bufOffset = mUCSOffset(p) as Long;
				val length = mUCSCount(p) as Long;
				assert (mUCSOffset(p + 1) - bufOffset == length);
				MemoryChunk.copy(mesTmp, tmpOffset, mesBuffer, bufOffset, length);
				MemoryChunk.copy(idsTmp, tmpOffset, idsBuffer, bufOffset, length);
			});
			
			mesCount.del();
			mesOffset.del();
			mesTmp.del();
			idsTmp.del();
		}
		else {
			mUCSIds = idsTmp;
			mUCSMessages = mesTmp;
			numCombinedMessages = numMessages;
		}
		
		return numCombinedMessages;
	}
	
	private def numLocalVertexesBC() = Math.max(
			mIds.numberOfLocalVertexes2N(), Bitmap.BitsPerWord as Long);
	
	private def createInEdgesMask() {
		val numLocalVertexes2N = mIds.numberOfLocalVertexes2N();
		val numVertexesBC = numLocalVertexesBC() * mTeam.size();
		val tmpMask = new Bitmap(numVertexesBC, false);
		if(mInEdgesMask == null) mInEdgesMask = new Bitmap(numVertexesBC);
		
		Parallel.iter(mInEdgesVertex.range(), (tid :Long, r :LongRange) => {
			for(i in r) tmpMask.atomicSet(mInEdgesVertex(i));
		});
		
		// unpack bitmap if it is needed
		if(numLocalVertexes2N < Bitmap.BitsPerWord) {
			val raw = tmpMask.raw();
			val numBits = numLocalVertexes2N as Int;
			val mask = (1L << numBits) - 1;
			for (var p :Int = mTeam.size()-1; p >= 0; --p) {
				val shift = (numBits * p) % Bitmap.BitsPerWord;
				raw(p) = (raw(Bitmap.offset(numBits * p)) >> shift) & mask;
			}
		}
		
		mTeam.alltoall(tmpMask.raw(), mInEdgesMask.raw());
		tmpMask.del();
	}
	
	private def processBroadcastMessages() :Long {
		val numLocalVertexesBC = numLocalVertexesBC();
		val numVertexesBC = numLocalVertexesBC * mTeam.size();
		val numPlaces = mTeam.size();
		val nullMessage = Zero.get[M]();
		
		if(mInEdgesMask == null) createInEdgesMask();
		
		mBCSMask = new Bitmap(numVertexesBC);
		mBCSCount = new MemoryChunk[Int](numPlaces);
		mBCSOffset = new MemoryChunk[Int](numPlaces + 1);
		
		Parallel.iter(0L..(numPlaces-1), (p :Long) => {
			val startWordOffset = Math.max(Bitmap.offset(numLocalVertexesBC * p), p);
			val lengthInWords = Bitmap.numWords(numLocalVertexesBC);
			val placeHasMessage = mBCSMask.raw().subpart(startWordOffset, lengthInWords);
			val placeInEdgeMask = mInEdgesMask.raw().subpart(startWordOffset, lengthInWords);
			val rawHasMessage = mBCCHasMessage.raw();
			
			var placeNumMessage :Int = 0;
			// The size of mBCCHasMessage is the actual number of vertexes (NumberOfLocalVertexes).
			// But the size of placeHasMessage and placeInEdgeMask is the power of 2 number (NumberOfLocalVertexes2N).
			for(i in 0..(rawHasMessage.size()-1)) {
				placeHasMessage(i) = rawHasMessage(i) & placeInEdgeMask(i);
				placeNumMessage += MathAppend.popcount(placeHasMessage(i));
			}
			for(i in rawHasMessage.size()..(placeInEdgeMask.size()-1)) {
				placeHasMessage(i) = 0L;
			}
			mBCSCount(p) = placeNumMessage;
		});
		
		Parallel.iter(mBCCHasMessage.raw().range(), (tid :Long, r :LongRange) => {
			val rawHasMessage = mBCCHasMessage.raw();
			for(i in r) rawHasMessage(i) = 0UL; // clear bitmap
		});
		
		mBCSOffset(0) = 0;
		for(i in 0..(numPlaces-1)) {
			mBCSOffset(i + 1) = mBCSOffset(i) + mBCSCount(i);
		}
		
		mBCSMessages = new MemoryChunk[M](mBCSOffset(numPlaces));

		Parallel.iter(0L..(numPlaces-1), (p :Long) => {
			val startWordOffset = Math.max(Bitmap.offset(numLocalVertexesBC * p), p);
			val lengthInWords = Bitmap.numWords(numLocalVertexesBC);
			val placeHasMessage = new Bitmap(mBCSMask.raw().subpart(startWordOffset, lengthInWords));
			
			val start = mBCSOffset(p);
			val length = mBCSCount(p);
			val mesLocalBuffer = mBCSMessages.subpart(start, length);
			
			var offset :Int = 0L;
			for(i in mBCCMessages.range()) {
				if(placeHasMessage(i)) {
					mesLocalBuffer(offset++) = mBCCMessages(i);
				}
			}
			assert (offset == length);
		});

		return mBCSOffset(numPlaces);
	}
	
	def resetSRBuffer() {
		if(mUCRMessages.size() > 0) { mUCRMessages.del(); mUCRMessages = new MemoryChunk[M](); }
		if(mUCROffset.size() > 0) {mUCROffset.del(); mUCROffset = new MemoryChunk[Long]();}
		if(mBCRHasMessage != null) {mBCRHasMessage.del(); mBCRHasMessage = null; }
		if(mBCROffset.size() > 0) { mBCROffset.del(); mBCROffset = new MemoryChunk[Long](); }
		if(mBCRMessages.size() > 0) { mBCRMessages.del(); mBCRMessages = new MemoryChunk[M]();}
	}
	
	def preProcess() {
		resetSRBuffer();

		mUCSRawMessageCount = Algorithm.reduce(mUCCMessages.range(),
				(i:Long) => mUCCMessages(i).messages.size());
		
		return [ mNumActiveVertexes, mUCSRawMessageCount, mBCSInputCount ];
	}
	
	def process(combine : (MemoryChunk[M]) => M, UCEnabled :Boolean, BCEnabled :Boolean) {
		
		val numCombinedMessages = UCEnabled ? processUnicastMessages(combine) : 0L;
		val numTransferedVertexMessages = BCEnabled ? processBroadcastMessages() : 0L;

		mUCSRawMessageCount = 0L;
		mBCSInputCount = 0L;
		mNumActiveVertexes = 0L;
		
		return [ numCombinedMessages, numTransferedVertexMessages ];
	}
	
	def exchangeMessages(UCEnabled :Boolean, BCEnabled :Boolean) :void {
		@Ifdef("PROF_XP") val mtimer = Config.get().profXPregel().timer(XP.MAIN_FRAME, 0);
		val numPlaces = mTeam.size();
		val recvCount = new MemoryChunk[Int](numPlaces);
		val recvOffset = new MemoryChunk[Int](numPlaces + 1);

		mUCREnabled = UCEnabled;
		mBCREnabled = BCEnabled;
		
		if(UCEnabled) {
			
			mTeam.alltoall(mUCSCount, recvCount);
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_COMM_COUNT); }
			
			recvOffset(0) = 0;
			for(i in recvCount.range()) {
				recvOffset(i + 1) = recvOffset(i) + recvCount(i);
			}
			
			val recvSize = recvOffset(numPlaces);

			val UCRIdsTmp = new MemoryChunk[Long](recvSize);
			mTeam.alltoallv(mUCSIds, mUCSOffset, mUCSCount, UCRIdsTmp, recvOffset, recvCount);
			mUCSIds.del();

			val UCRMessagesTmp = new MemoryChunk[M](recvSize);
			mTeam.alltoallv(mUCSMessages, mUCSOffset, mUCSCount, UCRMessagesTmp, recvOffset, recvCount);
			mUCSMessages.del();
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_UC_COMM); }
			
			mUCSCount.del();
			mUCSOffset.del();

			val UCRIds = new MemoryChunk[Long](recvSize);
			mUCRMessages = new MemoryChunk[M](recvSize);
			
			Parallel.sort(mIds.lgl, UCRIdsTmp, UCRMessagesTmp, UCRIds, mUCRMessages);
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_UC_SORT); }

			UCRMessagesTmp.del();
			UCRIdsTmp.del();
			
			val numLocalVertexes = mIds.numberOfLocalVertexes();
			mUCROffset = new MemoryChunk[Long](numLocalVertexes+1);
			Parallel.makeOffset(UCRIds, mUCROffset);
			UCRIds.del();
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_UC_MAKE_OFFSET); }
		}
		
		if(BCEnabled) {
			val numLocalVertexes2N = mIds.numberOfLocalVertexes2N();
			val numLocalVertexesBC = numLocalVertexesBC();
			
			mTeam.alltoall(mBCSCount, recvCount);
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_COMM_COUNT); }
			
			recvOffset(0) = 0;
			for(i in recvCount.range()) {
				recvOffset(i + 1) = recvOffset(i) + recvCount(i);
			}

			val recvSize = recvOffset(numPlaces);
			
			mBCRMessages = new MemoryChunk[M](recvSize);
			mTeam.alltoallv(mBCSMessages, mBCSOffset, mBCSCount, mBCRMessages, recvOffset, recvCount);
			mBCSMessages.del();
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_BC_COMM_MES); }

			mBCRHasMessage = new Bitmap(numLocalVertexesBC * numPlaces);
			mTeam.alltoall(mBCSMask.raw(), mBCRHasMessage.raw());
			mBCSMask.del();
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_BC_COMM_MASK); }
			
			// pack mBCRHasMessage if it is needed
			if(numLocalVertexes2N < Bitmap.BitsPerWord) {
				val dst = new Bitmap(mIds.numberOfGlobalVertexes2N(), false);
				val raw = dst.raw();
				val numBits = numLocalVertexes2N as Int;
				for(p in 0..(numPlaces-1)) {
					val shift = (numBits * p) % Bitmap.BitsPerWord;
					raw(Bitmap.offset(numBits * p)) |= mBCRHasMessage.word(p) << shift;
				}
				mBCRHasMessage = dst;
			}
			
			mBCROffset = new MemoryChunk[Long](Bitmap.numWords(mBCRHasMessage.size()) + 1);
			Parallel.scan(mBCRHasMessage.raw().range(), mBCROffset, 0L,
					(i:Long, v:Long) => MathAppend.popcount(mBCRHasMessage.word(i)) + v,
					(v1:Long, v2:Long) => v1 + v2);
			
			assert recvOffset(numPlaces) as Long ==
				mBCROffset(Bitmap.numWords(numLocalVertexes2N * numPlaces));
			@Ifdef("PROF_XP") { mtimer.lap(XP.MAIN_BC_MAKE_OFFSET); }
		}

		recvCount.del();
		recvOffset.del();
	}
}

