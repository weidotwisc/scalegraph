package org.scalegraph.xpregel;

import org.scalegraph.util.MemoryChunk;
import org.scalegraph.util.GrowableMemory;
import org.scalegraph.util.tuple.Tuple2;
import org.scalegraph.util.Bitmap;

/**
 * Provides XPregel framework service for compute kernels. <br>
 * The vertex id is processed in the mangled format,
 * we call <i>dst id format</i>, for optimization. You can get
 * the real vertex id with realId() method.
 * 
 * V: Vertex value type
 * E: Edge value type
 * M: Message value type
 * A: Aggreator value type
 */
public class VertexContext[V, E, M, A] {V haszero, E haszero, M haszero, A haszero } {
	val mWorker :WorkerPlaceGraph[V, E];
	val mCtx :MessageCommunicator[M];
	val mEdgeProvider :EdgeProvider[E];

	// messages
	val mEOCMessages :MemoryChunk[MessageBuffer[M]];
	
	// aggregate values
	var mAggregatedValue :A;
	val mAggregateValue :GrowableMemory[A] = new GrowableMemory[A]();

	var mSrcid :Long;
	
	var mNumVOMes :Long = 0L; // TODO:
	
	def this(worker :WorkerPlaceGraph[V, E], ctx :MessageCommunicator[M], tid :Long) {
		mWorker = worker;
		mCtx = ctx;
		mEdgeProvider = new EdgeProvider[E](worker.mOutEdge, worker.mInEdge);
		mEOCMessages = mCtx.messageBuffer(tid);
	}
	
	/**
	 * get the number of current superstep
	 */
	public def superstep() = mCtx.mSuperstep;

	/**
	 * get the vertex id
	 */
	public def id() = mCtx.mStoD(mSrcid);

	/**
	 * get the minimum vertex id of the region assigned to the current place
	 */
	public def placeBaseVertexId() = mCtx.mStoD(0L);
	
	/**
	 * get real vertex id from dst id
	 */
	public def realId(id :Long) = mCtx.mDtoV(id);
	
	/**
	 * get dst id from read vertex id
	 */
	public def dstId(realId :Long) = mCtx.mVtoD(realId);
	
	/**
	 * get the number of vertices of the graph
	 */
	public def numberOfVertices() = mWorker.mIds.numberOfGlobalVertexes();
	
	/**
	 * get the value for the current vertex
	 */
	public def value() = mWorker.mVertexValue(mSrcid);
	
	/**
	 * set the value for the current vertex
	 */
	public def setValue(value :V) { mWorker.mVertexValue(mSrcid) = value; }
	
	/**
	 * returns <vertex dst ids, values>
	 */
	public def outEdges() = mEdgeProvider.outEdges(mSrcid);
	
	/**
	 * get out edges for the current vertex
	 */
	public def outEdgesId() = mEdgeProvider.outEdgesId(mSrcid);

	/**
	 * get out edges for the current vertex
	 */
	public def outEdgesValue() = mEdgeProvider.outEdgesValue(mSrcid);
	
	/**
	 * get in edges for the current vertex
	 */
	public def inEdgesId() = mEdgeProvider.inEdgesId(mSrcid);
	
	/**
	 * get in edges for the current vertex
	 */
	public def inEdgesValue() = mEdgeProvider.inEdgesValue(mSrcid);
	
	/**
	 * replace the out edges for the current vertex with the given edges
	 */
	public def setOutEdges(id :MemoryChunk[Long], value :MemoryChunk[E]) {
		mEdgeProvider.setOutEdges(id, value);
	}
	
	/**
	 * remove all the out edges for the current vertex
	 */
	public def clearOutEdges() { mEdgeProvider.clearOutEdges(); }
	
	/**
	 * add out edge to the current vertex
	 */
	public def addOutEdge(id :Long, value :E) { mEdgeProvider.addOutEdge(id, value); }
	
	/**
	 * add out edges to the current vertex
	 */
	public def addOutEdges(id :MemoryChunk[Long], value :MemoryChunk[E]) {
		mEdgeProvider.addOutEdges(id, value);
	}

	/**
	 * get aggregated value on a previous superstep
	 */
	public def aggregatedValue() = mAggregatedValue;

	/**
	 * aggregate the value
	 */
	public def aggregate(value :A) { mAggregateValue.add(value); }

	/**
	 * send message using dst id of 
	 * vertex
	 */
	public def sendMessage(id :Long, mes :M) {
		val dstPlace = mCtx.mDtoV.c(id);
		val srcId = mCtx.mDtoS(id);
		val mesBuf = mEOCMessages(dstPlace);
		mesBuf.messages.add(mes);
		mesBuf.dstIds.add(srcId);
	}

	/**
	 * send messages using dst id of 
	 * vertex
	 */
	public def sendMessage(id :MemoryChunk[Long], mes :MemoryChunk[M]) {
		for(i in id.range()) {
			val dstPlace = mCtx.mDtoV.c(id(i));
			val srcId = mCtx.mDtoS(id(i));
			val mesBuf = mEOCMessages(dstPlace);
			mesBuf.messages.add(mes(i));
			mesBuf.dstIds.add(srcId);
		}
	}

	/**
	 * send messages to all neighbor vertices
	 * This method uses in edges to send messages.
	 * Before using this method, you have to update in edges
	 * by invoking updateInEdges method of XPregelGraph.
	 */
	public def sendMessageToAllNeighbors(mes :M) {
		// TODO: handle multiple messages
		++mNumVOMes;
		mCtx.mVOCHasMessage(mSrcid) = true;
		mCtx.mVOCMessages(mSrcid) = mes;
	}
	
	/**
	 * make the halted flag for the current vertex true
	 */
	public def voteToHalt() {
		mWorker.mVertexActive(mSrcid) = false;
	}
	
	/**
	 * make the halted flag for the current vertex false
	 */
	public def revive() {
		mWorker.mVertexActive(mSrcid) = true;
	}
	
	/**
	 * set the initial halted flag value for the current vertex on the next computation
	 */
	public def setVertexShouldBeActive(active :Boolean) {
		mWorker.mVertexShouldBeActive(mSrcid) = active;
	}
	
	/**
	 * get the halted flag for the current vertex
	 */
	public def isHalted() = mWorker.mVertexActive(mSrcid);
}


