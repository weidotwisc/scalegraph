package org.scalegraph.metrics;

import org.scalegraph.graph.*;
import x10.io.SerialData;
import x10.util.ArrayList;
import x10.util.IndexedMemoryChunk;
import x10.util.concurrent.Lock;
import x10.util.GrowableIndexedMemoryChunk;
import x10.util.Team;
import org.scalegraph.util.MemoryChunk;
import org.scalegraph.concurrent.Dist2D;
import x10.compiler.Inline;
import org.scalegraph.metrics.DistBetweennessCentrality.Bitmap;
import org.scalegraph.util.DistMemoryChunk;
import x10.compiler.Native;


public class DistBetweennessCentralityWeighted implements x10.io.CustomSerialization{

    private static type Vertex = Long;
    // private static type Bucket = ArrayList[Vertex];
    private static type Bucket = Array[Bitmap]{self.size == 2};
    private static type Buckets = GrowableIndexedMemoryChunk[Bucket];
    private static type BucketIndex = Int;
    
    private val MAX_BUCKET_INDEX = Int.MAX_VALUE;
    
    private val team: Team;
    private val places: PlaceGroup;
    private val lgl: Int;
    private val lgc: Int;
    private val lgr: Int;
    private val role: Int;
    
//     
//     protected def distance() = localHandle().lcDistance;
//     protected def score() = localHandle().lcScore;
//     protected def predecessors() = localHandle().lcPredecessor;
//     protected def successors() = localHandle().lcSuccessor;
//     protected def graph() = localHandle().lcGraph;
//     protected def buckets() = localHandle().lcBuckets;
//     protected def isDeletedMap() = localHandle().lcIsDeleted;
//     protected def currentBucket() = localHandle().lcCurrentBucket;
//     protected def deletedVertices() = localHandle().lcDeletedVertices;
//     protected def delta() = localHandle().lcDelta;
//     protected def currentTraverseQ() = localHandle().lcCurrentTraverseQ;
//     protected def nextTraverseQ() = localHandle().lcNextTraverseQ;
//     protected def nonIncDistCurrentQ() = localHandle().lcNonIncreaseDistanceCurrentQ;
//     protected def nonIncDistNextQ() = localHandle().lcNonIncreaseDistanceNextQ;
//     protected def updates() = localHandle().lcUpdates;
//     protected def dependencies() = localHandle().lcDependencies;
//     
//     // Reuse distance array
//     protected def pathCount() = localHandle().lcPathCount;
// 
//     protected def currentSource() = localHandle().lcCurrentSource;
    
    private val lch: PlaceLocalHandle[LocalState];
    
    private static class LocalState {
        
        val gCsr: DistSparseMatrix;
        val gWeight: DistMemoryChunk[Double];
        val csr: SparseMatrix;
        val weight: MemoryChunk[Double];
        val distance: IndexedMemoryChunk[Long];
        val dependencies: IndexedMemoryChunk[Double];
        val score: IndexedMemoryChunk[Double];
        val geodesicPath: IndexedMemoryChunk[Long];
        val predecessors: IndexedMemoryChunk[ArrayList[Vertex]];
        val successors: IndexedMemoryChunk[ArrayList[Vertex]];
        val successorCount: IndexedMemoryChunk[Int];
        val deletedVertexMap: Bitmap;
        val deferredVertex: Bitmap;
        val delta: Int;
        val linearScale: Boolean = false;
        
        val currentSource: Cell[Vertex];
        val currentBucketIndex: Cell[Int];
        val bucketQueuePointer: Cell[Int];
        val numLocalVertices: Long;
        
        val ALIGN = 64;
        val CONGRUENT = false;
        val BUFFER_SIZE: Int;
        val INIT_BUCKET_SIZE = 32;
        val NUM_TASK: Int;
        val buckets: Buckets;
        
        val semaphore: IndexedMemoryChunk[Long];
        
        // traverse in non-increasing order of distance staff
        val currentLevel: Cell[Long];
        val queues: IndexedMemoryChunk[Bitmap];
        val pathCount: IndexedMemoryChunk[Long];
        val level: IndexedMemoryChunk[Long];
        
        // poniters of current queue and next queue
        val qPointer: Cell[Int];
        
        // Backtracking
        val numUpdates: IndexedMemoryChunk[Int];
        val backtrackingQueues: IndexedMemoryChunk[Bitmap];
        val backtrackingQPointer: Cell[Int];
        
        // buffer
        val predBuf: Array[Array[ArrayList[Vertex]]];
        val succBuf: Array[Array[ArrayList[Vertex]]];
        val sigmaBuf: Array[Array[ArrayList[Long]]];
        val deltaBuf: Array[Array[ArrayList[Double]]];
        val muBuf: Array[Array[ArrayList[Long]]];
        
        // val lcPathCount: BigArray[Long];
        // val lcPredecessor: BigArray[ArrayList[VertexId]];
        // val lcSuccessor: BigArray[ArrayList[VertexId]];
        // val lcIsDeleted: BigArray[Boolean];
        // val lcDelta: Long;
        // val lcDeletedVertices: GrowableIndexedMemoryChunk[VertexId];
        // val lcBuckets: Bucket;
        // val lcScore: BigArray[Double];
        // val lcUpdates: BigArray[Int];
        // val lcDependencies: BigArray[Double];
        
        // var lcCurrentBucket: BucketIndex;
        // var lcCurrentTraverseQ: FixedVertexQueue;
        // var lcNextTraverseQ: FixedVertexQueue;
        // var lcCurrentSource: VertexId;
        // var updateScoreLock: Lock;
        // var updateSuccessorLock: Lock;
        // var lcNonIncreaseDistanceCurrentQ: FixedVertexQueue;
        // var lcNonIncreaseDistanceNextQ: FixedVertexQueue;
        
        protected def this (csr_: DistSparseMatrix,
                            weight_: DistMemoryChunk[Double],
                            transferBufSize: Int,
                            delta_: Int) {
            gCsr = csr_;
            csr = gCsr();
            gWeight = weight_;
            weight = gWeight();
            BUFFER_SIZE = transferBufSize;
            numLocalVertices = gCsr.ids().numberOfLocalVertexes();
            currentSource = new Cell[Vertex](0);
            currentBucketIndex = new Cell[Int](0);
            bucketQueuePointer = new Cell[Int](0);
            NUM_TASK = Runtime.NTHREADS;
            delta = delta_;
            
            distance = IndexedMemoryChunk.allocateZeroed[Long](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            geodesicPath = IndexedMemoryChunk.allocateZeroed[Long](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            predecessors = IndexedMemoryChunk.allocateZeroed[ArrayList[Vertex]](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            successors = IndexedMemoryChunk.allocateZeroed[ArrayList[Vertex]](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            successorCount = IndexedMemoryChunk.allocateZeroed[Int](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            pathCount = IndexedMemoryChunk.allocateZeroed[Long](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            level = IndexedMemoryChunk.allocateZeroed[Long](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            dependencies = IndexedMemoryChunk.allocateZeroed[Double](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            score = IndexedMemoryChunk.allocateZeroed[Double](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            numUpdates = IndexedMemoryChunk.allocateZeroed[Int](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            semaphore = IndexedMemoryChunk.allocateZeroed[Long](
                    numLocalVertices,
                    ALIGN,
                    CONGRUENT);
            
            buckets = new Buckets(INIT_BUCKET_SIZE);
            val nVertices = numLocalVertices;
            for (i in 0..(INIT_BUCKET_SIZE - 1))
                buckets(i) = new Array[Bitmap](2, (Int) => new Bitmap(nVertices));
            deletedVertexMap = new Bitmap(numLocalVertices);
            deferredVertex = new Bitmap(numLocalVertices);
            
            for (i in 0..(numLocalVertices - 1)) {
                predecessors(i) = null;
            }
            
            currentLevel = new Cell[Long](0);
            queues = IndexedMemoryChunk.allocateUninitialized[Bitmap](2,
                    ALIGN,
                    CONGRUENT);
            queues(0) = new Bitmap(numLocalVertices);
            queues(1) = new Bitmap(numLocalVertices);
            qPointer = new Cell[Int](0);
            
            // Create queue for updating score
            backtrackingQueues = IndexedMemoryChunk.allocateUninitialized[Bitmap](
                    2, 
                    ALIGN,
                    CONGRUENT);
            backtrackingQueues(0) = new Bitmap(numLocalVertices);
            backtrackingQueues(1) = new Bitmap(numLocalVertices);
            backtrackingQPointer = new Cell[Int](0);
            
            val team = gCsr.dist().allTeam();
            predBuf = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                    (int) => new Array[ArrayList[Vertex]](team.size(),
                            (int) => new ArrayList[Vertex](transferBufSize)));
            succBuf = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                    (int) => new Array[ArrayList[Vertex]](team.size(),
                            (int) => new ArrayList[Vertex](transferBufSize)));
            sigmaBuf = new Array[Array[ArrayList[Long]]](NUM_TASK,
                    (int) => new Array[ArrayList[Long]](team.size(),
                            (int) => new ArrayList[Long](transferBufSize)));
            deltaBuf = new Array[Array[ArrayList[Double]]](NUM_TASK,
                    (int) => new Array[ArrayList[Double]](team.size(),
                            (int) => new ArrayList[Double](transferBufSize)));
            muBuf = new Array[Array[ArrayList[Long]]](NUM_TASK,
                    (int) => new Array[ArrayList[Long]](team.size(),
                            (int) => new ArrayList[Long](transferBufSize)));
        }
        // public def this(g: BigGraph,
        //                 currentSource: VertexId,
        //                 distance: BigArray[Long],
        //                 pathCount: BigArray[Long],
        //                 predecessor: BigArray[ArrayList[VertexId]],
        //                 successor: BigArray[ArrayList[VertexId]],
        //                 isDeleted: BigArray[Boolean],
        //                 delta: Long,
        //                 deletedVertices: GrowableIndexedMemoryChunk[VertexId],
        //                 buckets: Bucket,
        //                 currentBucket: BucketIndex,
        //                 currentTraverseQ: FixedVertexQueue,
        //                 nextTraverseQ: FixedVertexQueue,
        //                 score: BigArray[Double],
        //                 nonIncDistCurrentQ: FixedVertexQueue,
        //                 nonIncDistNextQ: FixedVertexQueue,
        //                 updates: BigArray[Int],
        //                 dependencies: BigArray[Double]) {
            
            // property(g, 
            //          distance,
            //          pathCount,
            //          predecessor, 
            //          successor, 
            //          isDeleted, 
            //          delta, 
            //          deletedVertices, 
            //          buckets,
            //          score,
            //          updates,
            //          dependencies);
            // 
            // this.lcCurrentBucket = currentBucket;
            // this.lcCurrentTraverseQ = currentTraverseQ;
            // this.lcNextTraverseQ = nextTraverseQ;
            // this.lcCurrentSource = currentSource;
            // this.lcNonIncreaseDistanceCurrentQ = nonIncDistCurrentQ;
            // this.lcNonIncreaseDistanceNextQ = nonIncDistNextQ;
            // this.updateScoreLock = new Lock();
            // this.updateSuccessorLock = new Lock();
        // }
    }
    
    protected def this(lch_: PlaceLocalHandle[LocalState]) {
        lch = lch_;
        team = lch().gCsr.dist().allTeam();
        places = team.placeGroup();
        lgl = lch().gCsr.ids().lgl;
        lgc = lch().gCsr.ids().lgc;
        lgr = lch().gCsr.ids().lgr;
        role = team.role(here)(0);
    }

    public def this(serialData: SerialData) {
        this( serialData.data as PlaceLocalHandle[LocalState]);
    }
    
    public def serialize(): SerialData {
        
        return new SerialData(lch, null);
    }
    
    public static def run(val g: Graph) {

        // val nodes = g.getVertexCount();
        // val distance = BigArray.make[Long](nodes);
        // val score = BigArray.make[Double](nodes);
        // val pathCount = BigArray.make[Long](nodes);
        // val predecessor = BigArray.make[ArrayList[VertexId]](nodes);
        // val successor = BigArray.make[ArrayList[VertexId]](nodes);
        // val isDeleted = BigArray.make[Boolean](nodes);
        // val updates = BigArray.make[Int](nodes);
        // val delta = 1;
        // val initBucketSize = 20;
        // val currentSource = 1L;
        // val dependecies = BigArray.make[Double](nodes);
        // 
        // val initBigBc = () => {
        //     
        //     val currentTraverseQ = new FixedVertexQueue(nodes);
        //     val nextTraverseQ = new FixedVertexQueue(nodes);
        //     val nonIncDistCurrentQ = new FixedVertexQueue(nodes);
        //     val nonIncDistNextQ = new FixedVertexQueue(nodes);
        //     val buckets = new Bucket(initBucketSize);
        //     
        //     // Init bucket
        //     for (var i: Int = 0; i < buckets.capacity(); ++i) {
        //         
        //         buckets.add(new ArrayList[VertexId]());
        //     }
        //     
        //     val initBucketIndex = 0L;
        //     
        //     return new LocalState(g,
        //                           currentSource,
        //                           distance,
        //                           pathCount,
        //                           predecessor,
        //                           successor,
        //                           isDeleted,
        //                           delta,
        //                           new GrowableIndexedMemoryChunk[VertexId](),
        //                           buckets,
        //                           initBucketIndex,
        //                           currentTraverseQ,
        //                           nextTraverseQ,
        //                           score,
        //                           nonIncDistCurrentQ,
        //                           nonIncDistNextQ,
        //                           updates,
        //                           dependecies);
        // };
        // 
        // // Create struct on each place
        // val dist = Dist.makeUnique();
        // val lch = PlaceLocalHandle.make[LocalState](dist, initBigBc);
        // val bc = new BigBetweennessCentralityWeighted(lch);
        val team = g.team();
        val places = team.placeGroup();
        val transBuf = 1 << 8;
        val delta = 1;
        // Represent graph as CSR
        val csr = g.constructDistSparseMatrix(
                                              Dist2D.make1D(team, Dist2D.DISTRIBUTE_COLUMNS),
                                              true,
                                              true);
        // Construct attribute
        val weightAttr = g.constructDistAttribute[Double](csr, false, "weight");
        // create local state for bc on each place
        val localState = PlaceLocalHandle.make[LocalState](places, () => {
            return new LocalState(csr, weightAttr, transBuf, delta);
        });
        val bc = new DistBetweennessCentralityWeighted(localState);
        bc.internalRun();
        // return bc.score();
    }
    
    /* GCC Built-in atomic function interface */
    @Native("c++", "__sync_bool_compare_and_swap((#imc)->raw() + #index, #oldVal, #newVal)")
    private static native def compare_and_swap[T](imc: IndexedMemoryChunk[T], index: Long, oldVal: T, newVal: T): Boolean;
    
    @Native("c++", "__sync_add_and_fetch((#imc)->raw() + #index, #value)")
    private static native def add_and_fetch[T](imc: IndexedMemoryChunk[T], index: Long, value: T): T;
    
    @Inline
    public def isLocalVertex(orgVertex: Vertex): Boolean {
        val vertexPlace = ((1 << (lgc + lgr)) -1) & orgVertex;
        if(vertexPlace == role as Long)
            return true;
        return false;
    }
    
    @Inline
    public def OrgToLocSrc(v: Vertex) 
    = (( v & (( 1 << lgr) -1)) << lgl) | (v >> (lgr + lgc));
    
    @Inline
    public def LocSrcToOrg(v: Vertex)
    = ((((v & (( 1 << lgl) -1)) << lgc)| role) << lgr) | (v>> lgl);
    
    @Inline
    public def LocDstToOrg(v: Vertex)
    = ((((v & (( 1 << lgl) -1)) << lgc | (v >> lgl)) << lgr ) | 0);
    
    @Inline
    private def getVertexPlace(orgVertex: Vertex): Place {
        return team.place(getVertexPlaceRole(orgVertex));
    }
    
    @Inline
    private def getVertexPlaceRole(orgVertex: Vertex): Int {
        val vertexPlaceId = ((1 << (lgc + lgr)) -1) & orgVertex;
        return vertexPlaceId as Int;
    }
    
    @Inline
    private def currentBucketIndex() = lch().currentBucketIndex;
    
    @Inline
    private def buckets() = lch().buckets;
    
    @Inline
    private def deletedVertexMap() = lch().deletedVertexMap;
    
    @Inline
    private def deferredVertex() = lch().deferredVertex;
    
    @Inline
    private def distance() = lch().distance;
    
    @Inline
    private def csr() = lch().csr;
    
    @Inline
    private def delta() = lch().delta;
    
    @Inline
    private def predecessors() = lch().predecessors;
    
    @Inline
    private def successors() = lch().successors;
    
    @Inline 
    private def successorCount() = lch().successorCount;
    
    @Inline
    private def weight() = lch().weight;
    
    @Inline
    private def currentBucketQueue() 
    = lch().buckets(lch().currentBucketIndex())(lch().bucketQueuePointer());
    
    @Inline
    private def nextBucketQueue() 
    = lch().buckets(lch().currentBucketIndex())((lch().bucketQueuePointer() + 1) & 1);
    
    @Inline
    private def swapBucket() {
        lch().bucketQueuePointer() = (lch().bucketQueuePointer() + 1) & 1;
    }
    
    @Inline
    private def currentTraverseQ() = lch().queues(lch().qPointer());
    
    @Inline
    private def nextTraverseQ() = lch().queues((lch().qPointer() + 1) & 1);
    
    @Inline
    private def swapTraverseQ() { lch().qPointer() = (lch().qPointer() + 1) & 1; }
    
    @Inline
    private def pathCount() = lch().pathCount;
    
    @Inline
    private def dependencies() = lch().dependencies;
    
    @Inline
    private def level() = lch().level;
    
    @Inline
    private def numUpdates() = lch().numUpdates;
    
    @Inline
    private def score() = lch().score;
    
    @Inline
    private def backtrackingCurrentQ() = lch().backtrackingQueues(lch().backtrackingQPointer());
    
    @Inline
    private def backtrackingNextQ() = lch().backtrackingQueues((lch().backtrackingQPointer() + 1) & 1);
    
    @Inline
    private def swapUpdateScoreQ() { lch().backtrackingQPointer() = (lch().backtrackingQPointer() + 1) & 1; }
    
    private def internalRun() {
        // cal complete BC
        var time: Long = System.currentTimeMillis();
        val startVertex = 0;
        val endVertex = 0;
        // for each source
        for(var v: Int = startVertex; v <= endVertex; ++v) {
            // set current source
            finish for(p in places) {
                val curSrc = v;
                at (p) async {     
                    clear();
                    calBC(curSrc);
                }
            }
        }
        time = System.currentTimeMillis() - time;
        print();
        Console.OUT.println("BC time: " + time);
    }
    
    private def clear() {
        // clear data local data
        for (i in 0..(lch().numLocalVertices - 1)) {
            lch().distance(i) = Long.MAX_VALUE;
            lch().geodesicPath(i) = 0;
        }
    }
    
    private def calBC(src: Vertex) {
        Console.OUT.println("Cal BC for source: " + src);
        Console.OUT.println("Start Delta stepping");
      
        lch().currentSource() = src;
        deltaStepping();
        Runtime.x10rtBlockingProbe();

        Console.OUT.println("Find Successors");
        deriveSuccessor();
        Runtime.x10rtBlockingProbe();
        
        Console.OUT.println("Count Path");
        travelInNonIncreasingOrder();
        Runtime.x10rtBlockingProbe();
       
        Console.OUT.println("Update score");
        updateScore();
        Runtime.x10rtBlockingProbe();        
    }
    
    protected def deltaStepping() {
        val bufSize = lch().BUFFER_SIZE;
        val NUM_TASK = lch().NUM_TASK;
        val bufferV = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        val bufferW = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        val bufferX = new Array[Array[ArrayList[Long]]](NUM_TASK,
                (int) => new Array[ArrayList[Long]](team.size(),
                        (int) => new ArrayList[Long](bufSize)));
        // Declare closures
        val clearBuffer = (threadId: Int, pid: Int) => {
            bufferV(threadId)(pid).clear();
            bufferW(threadId)(pid).clear();
            bufferX(threadId)(pid).clear();
        };
        val flush = (threadId: Int, pid: Int) => {
            // No data return
            if (bufferV(threadId)(pid).size() == 0)
                return;
            val relaxDataV = bufferV(threadId)(pid).toArray();
            val relaxDataW = bufferW(threadId)(pid).toArray();
            val relaxDataX = bufferX(threadId)(pid).toArray();
            val count = relaxDataV.size;
            at (team.place(pid)) {
                for(k in 0..(count - 1)) {
                    relax(relaxDataV(k),
                          relaxDataW(k),
                          relaxDataX(k));
                }
            }
            clearBuffer(threadId, pid);
        };
        val flushAll = () => {
            finish  for (i in 0..(NUM_TASK - 1)) {
                val k = i;
                async for (ii in 0..(team.size() - 1)) {
                    val kk = ii;
                    flush(k, kk);
                }
            }
        };
        val remoteRelax = (threadId: Int, pid: Int, v: Vertex, w: Vertex, x: Long) => {
            if (bufferV(threadId)(pid).size() == bufSize) {
                flush(threadId, pid);
            }
            bufferV(threadId)(pid).add(v);
            bufferW(threadId)(pid).add(w);
            bufferX(threadId)(pid).add(x);
        };       
        // Start delta stepping        
        var dataAvailable: Int = 0;
        val src = lch().currentSource();
        if (role == getVertexPlaceRole(src)) {
            relax(src, src, 0);
        }
        do {
            // clear bucket queue pointer, this makes nextqueue of another buckets deterministic
            lch().bucketQueuePointer() = 0;
            Team.WORLD.barrier(here.id);
            while (currentBucketIndex()() < buckets().capacity()
                    && (buckets()(currentBucketIndex()()) == null
                            || nextBucketQueue().setBitCount() == 0L)) {
                currentBucketIndex()() = currentBucketIndex()() + 1;
            }
            if (currentBucketIndex()() >= buckets().capacity()) {
                currentBucketIndex()() = MAX_BUCKET_INDEX; 
            }
            // Find smallest bucket
            currentBucketIndex()() = Team.WORLD.allreduce(role, currentBucketIndex()(), Team.MIN);
            if (currentBucketIndex()() == MAX_BUCKET_INDEX) {
                // No more work to do
                break;
            }
            deletedVertexMap().clearAll();
            do {
                Console.OUT.println(here.id + ":Loop: index-> " + currentBucketIndex());
                if (currentBucketIndex()() < buckets().capacity()
                        && buckets()(currentBucketIndex()()) != null) {
                    swapBucket();
                    nextBucketQueue().clearAll();
                    
                    val cBucket = currentBucketQueue();
                    cBucket.examine((localV: Long, threadId: Int) => {
                        val v = LocSrcToOrg(localV);
                        if (deletedVertexMap().isNotSet(localV)) {
                            deletedVertexMap().set(localV);
                        }
                        val vDist = distance()(localV);
                        val neighbours = csr().adjacency(localV);
                        val neighboursWeight = csr().attribute(weight(), localV);
                        for (i in 0..(neighbours.size() - 1)) {
                            val localW = neighbours(i);
                            val w = LocDstToOrg(localW);
                            val wWeight = neighboursWeight(i) as Long;                            
                            if (wWeight <= delta()) {
                                if (isLocalVertex(w)) {
                                    relax(v, w, vDist + wWeight);
                                } else {
                                    val pid = getVertexPlaceRole(w);
                                    // at(team.place(pid)) relax(v, w, vDist + wWeight);
                                    remoteRelax(threadId, pid, v, w, vDist + wWeight);
                                    // Console.OUT.println("remoteRelax: " + v + " " + w + " : " + vDist);
                                }
                            } else {
                                deferredVertex().set(localV);
                            }
                        }
                    });
                    flushAll();
                }
                Team.WORLD.barrier(here.id);
                if (currentBucketIndex()() < buckets().capacity()
                        && buckets()(currentBucketIndex()()) != null
                        && nextBucketQueue().setBitCount() > 0) {
                    dataAvailable = 1;
                } else {
                    dataAvailable = 0;
                }
                dataAvailable = Team.WORLD.allreduce(here.id, dataAvailable, Team.MAX);
            } while (dataAvailable > 0);
            
            // Relax heavy edges
            deferredVertex().examine((localV: Long, threadId: Int) => {
                val v = LocSrcToOrg(localV);
                val vDist = distance()(localV);
                val neighbours = csr().adjacency(localV);
                val neighbourWeight = csr().attribute(weight(), localV);
                for (w in neighbours) {
                    val wWeight = neighbourWeight(w) as Long;
                    if (wWeight > delta()) {
                        if (isLocalVertex(w)) {
                            relax(v, w, vDist + wWeight);
                        }  else {
                            val pid = getVertexPlaceRole(w);
                            remoteRelax(threadId, pid, v, w, vDist + wWeight);
                            Console.OUT.println("Heavy remoteRelax: " + v + " " + w + " : " + vDist);
                        }
                    }
                }
                throw new UnsupportedOperationException("have not tested yet");
            });
            flushAll();
            currentBucketIndex()() = currentBucketIndex()() + 1; 
        } while (true);
    }
    
    private def relax(v: Vertex, w: Vertex, x: Long) {  
        val localW = OrgToLocSrc(w);  
        while (true) {
            // non-blocking mutual exclusion
            // increase semaphore
            if (compare_and_swap[Long](lch().semaphore, localW, 0, 1)) {
                val wDist = distance()(localW);
                var tentative: Long = x;
                // Console.OUT.println("Relax: " + v + ", " + w + " : " + x);
                if (tentative < wDist) {
                    val newIndex = (tentative / delta()) as BucketIndex;
                    if (newIndex >= buckets().capacity()) {
                        atomic {
                            // recheck after acquiring lock
                            // TODO: implement non-blocking mutual exclusion, though it may improve the performance
                            // a little bit
                            // TODO: Test more on mutual exclusion, it seems we need lock every op that use bucket
                            if(newIndex >= buckets().capacity()) {
                                val growth = 10;
                                val oldCap = buckets().capacity();
                                val newCap = growth + newIndex;
                                buckets().grow(newCap);
                                for(k in 0..(newCap - oldCap - 1)) {
                                    buckets().add(new Array[Bitmap](2, 
                                            (Int) => new Bitmap(lch().numLocalVertices)));
                                }
                            }
                        }
                    }
                    val getNextBucket = (index: Int) => {
                        return index == lch().currentBucketIndex() ?
                                lch().buckets(index)((lch().bucketQueuePointer() + 1) & 1):                            
                                    lch().buckets(index)(1); // another index, 1st index is next q
                    };
                    if (wDist != Long.MAX_VALUE && deletedVertexMap().isSet(localW)) {
                        val oldIndex = (wDist / delta()) as BucketIndex;
                        if (oldIndex != newIndex) {
                            // Modifed only if changing bucket
                            val oldBucket = getNextBucket(oldIndex);
                            oldBucket.clear(localW);
                            val nextBucket = getNextBucket(newIndex);
                            nextBucket.set(localW);
                        }
                    } else {
                        // vertex has not been added to bucket
                        val nextBucket = getNextBucket(newIndex);
                        nextBucket.set(localW);
                    }
                    
                    distance()(localW) = tentative;
                    
                    if (predecessors()(localW) == null) {
                        predecessors()(localW) = new ArrayList[Vertex]();
                    }
                    predecessors()(localW).clear();
                    predecessors()(localW).add(v);
                } else if (tentative == wDist && v != w) {
                    predecessors()(localW).add(v);
                }
                while(true){
                    if(compare_and_swap[Long](lch().semaphore, localW, 1, 0))
                        break;
                }
                break;
            } 
        }
    }
    
    private def deriveSuccessor() {
        // Closure for managing remote op
        val bufSize = lch().BUFFER_SIZE;
        val NUM_TASK = lch().NUM_TASK;        
        val bufferP = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        val bufferS = new Array[Array[ArrayList[Vertex]]](NUM_TASK,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        val addSuccessor = (p: Long, s: Long) => {
            val localP = OrgToLocSrc(p);
            while (true) {
                // non-blocking mutual exclusion
                // increase semaphore
                if (compare_and_swap[Long](lch().semaphore, localP, 0, 1)) {
                    if (successors()(localP) == null) {
                        successors()(localP) = new ArrayList[Vertex]();
                    }
                    successors()(localP).add(s);
                    successorCount()(localP) = successorCount()(localP) + 1; 
                    while(true){
                        if(compare_and_swap[Long](lch().semaphore, localP, 1, 0))
                            break;
                    }
                    break;
                }
            }
        };
        // Closure for remote op
        val clearBuffer = (threadId: Int, pid: Int) => {
            bufferP(threadId)(pid).clear();
            bufferS(threadId)(pid).clear();
        };
        val flush = (threadId: Int, pid: Int) => {
            // No data return
            if (bufferP(threadId)(pid).size() == 0)
                return;
            val p = bufferP(threadId)(pid).toArray();
            val s = bufferS(threadId)(pid).toArray();
            val count = p.size;
            at (Place.place(pid)) {
                for(k in 0..(count - 1)) {
                    addSuccessor(p(k),
                                 s(k));
                }
            }
            clearBuffer(threadId, pid);
        };
        val flushAll = () => {
            finish  for (i in 0..(NUM_TASK - 1)) {
                val k = i;
                async for (ii in 0..(team.size() - 1)) {
                    val kk = ii;
                    flush(k, kk);
                }
            }
        };
        val remoteAddSuccessor = (threadId: Int, pid: Int, p: Vertex, s: Vertex) => {
            if (bufferP(threadId)(pid).size() >= bufSize) {
                flush(threadId, pid);
            }
            bufferP(threadId)(pid).add(p);
            bufferS(threadId)(pid).add(s);
        };
        DistBetweennessCentrality.iter(0..(lch().numLocalVertices - 1),
                                       (localS: Long, threadId: Int) => {
                                          val preds = predecessors()(localS);
                                          if (preds != null) {
                                              val succ = LocSrcToOrg(localS);
                                              for (i in 0..(preds.size() - 1)) {
                                                  val pred = preds(i);
                                                  if (isLocalVertex(pred)) {
                                                      addSuccessor(pred, succ);
                                                  } else {
                                                      val pid = getVertexPlaceRole(pred);
                                                      remoteAddSuccessor(threadId, pid, pred, succ);
                                                  }
                                              }
                                          }
                                       });
        flushAll();
    }
    
    private def visit(orgSrc: Long, orgDst: Long, predDistance: Long, predSigma: Long) {
        val localDst = OrgToLocSrc(orgDst);
        val d = predDistance + 1;
        val f = () => {
            // increase the number of geodesic paths
            add_and_fetch[Long](pathCount(), localDst, predSigma);
        };
        if (compare_and_swap(level(), localDst, 0L, d)) {
            // First visit
            nextTraverseQ().set(localDst);
        }         
        if (level()(localDst) == d){
            // Another shortest path
            f();
        }
    }
    
    private def travelInNonIncreasingOrder() {
        val bufSize = lch().BUFFER_SIZE;
        val numTask = lch().NUM_TASK;
        val predBuf = lch().predBuf;
        val succBuf = lch().succBuf;
        val sigmaBuf = lch().sigmaBuf;
        
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
            succBuf(bufId)(pid).clear();
            sigmaBuf(bufId)(pid).clear();
        };
        val _flush = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toArray();
            val succs = succBuf(bufId)(pid).toArray();
            val predSigma = sigmaBuf(bufId)(pid).toArray();
            val count = preds.size;
            val p = team.place(pid);
            at (p)  {
                for(k in 0..(count - 1)) {
                    val lv = lch().currentLevel();
                    visit(preds(k), succs(k), lv, predSigma(k));
                }
            }
            clearBuffer(bufId, pid);
        };
        val _flushAll = () => {
            finish for (i in 0..(numTask -1))
                async for (ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flush(i, ii);
                }
        };
        val _visitRemote = (bufId: Int, pid: Int, pred: Vertex, succ: Vertex, predSigma: Long) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flush(bufId, pid);
            } 
            predBuf(bufId)(pid).add(pred);
            succBuf(bufId)(pid).add(succ);
            sigmaBuf(bufId)(pid).add(predSigma);
        };
        // put source
        val src = lch().currentSource();
        if (isLocalVertex(src)) {
            val locSrc = OrgToLocSrc(src);
            nextTraverseQ().set(locSrc);
            level()(locSrc) = 0L;
            pathCount()(locSrc) = 1L;
        }
        while(true) {
            swapTraverseQ();
            nextTraverseQ().clearAll();
            // Check wether there is a vertex on such a place
            val maxVertexCount = team.allreduce(role,
                                                currentTraverseQ().setBitCount(),
                                                Team.MAX);
            if (maxVertexCount == 0L)
                break;
            val traverse = (localSrc: Vertex, threadId: Int) => {           
                val neighbors = successors()(localSrc);
                if (neighbors == null) {
                    // No successor is leave node
                    backtrackingNextQ().set(localSrc);
                } else {
                    val predDistance = level()(localSrc);
                    val predSigma = pathCount()(localSrc);
                    val orgSrc = LocSrcToOrg(localSrc);                        
                    for(i in 0..(neighbors.size() - 1)) {
                        val orgDst = LocDstToOrg(neighbors(i));
                        if (isLocalVertex(orgDst))  {
                            visit(orgSrc, orgDst, predDistance, predSigma);
                        } else {
                            val bufId = threadId;
                            val p: Place = getVertexPlace(orgDst);
                            _visitRemote(bufId, team.role(p)(0), orgSrc, orgDst, predSigma);
                        }    
                    }
                }
            };
            currentTraverseQ().examine(traverse);
            _flushAll();
            team.barrier(role);
            lch().currentLevel(lch().currentLevel() + 1);
        }
    }
    
    private def updateScore() {
        val bufSize = lch().BUFFER_SIZE;
        val numTask = lch().NUM_TASK;
        val predBuf = lch().predBuf;
        val deltaBuf = lch().deltaBuf;
        val sigmaBuf = lch().sigmaBuf;
        val muBuf = lch().muBuf;
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
            deltaBuf(bufId)(pid).clear();
            sigmaBuf(bufId)(pid).clear();
            muBuf(bufId)(pid).clear();
        };
        val _flush = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toArray();
            val delta = deltaBuf(bufId)(pid).toArray();
            val sigma = sigmaBuf(bufId)(pid).toArray();
            val mu = muBuf(bufId)(pid).toArray();
            val p = team.place(pid);
            at (p) {
                for(k in 0..(preds.size - 1)) {
                    val pred = preds(k);
                    calDependency(mu(k), delta(k), sigma(k), preds(k));
                }
            }
            clearBuffer(bufId, pid);
        };
        val _flushAll = () => {
            finish for (i in 0..(numTask -1))
                async for ( ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flush(i, ii);
                }
        };
        val calRemote = (bufId: Int, pid: Int, mu: Long, delta: Double, signma: Long, pred: Vertex) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flush(bufId, pid);
            } 
            muBuf(bufId)(pid).add(mu);
            deltaBuf(bufId)(pid).add(delta);
            sigmaBuf(bufId)(pid).add(signma);
            predBuf(bufId)(pid).add(pred);
        };
        while(true) {
            swapUpdateScoreQ();
            backtrackingNextQ().clearAll();
            team.barrier(role);
            // Check wether there is a vertex on such a place
            val maxVertexCount = team.allreduce(role, backtrackingCurrentQ().setBitCount(), Team.MAX);
            if (maxVertexCount == 0L)
                break;
            val traverse = (localSucc: Vertex, threadId: Int) => {           
                val predList = predecessors()(localSucc);
                val orgSucc = LocSrcToOrg(localSucc);
                if (predList != null && predList.size() > 0) {
                    val sz = predList.size();
                    for (i in 0..(sz -1)) {  
                        val pred = predList(i);
                        val w_sigma = pathCount()(localSucc);
                        val w_delta = dependencies()(localSucc);
                        val w_mu = distance()(localSucc);
                        if (isLocalVertex(pred))  {
                            calDependency(w_mu, w_delta, w_sigma, pred);
                        } else {
                            val bufId = threadId;
                            val pid = getVertexPlaceRole(pred);
                            calRemote(threadId, pid, w_mu, w_delta, w_sigma, pred);
                        }    
                    }
                }
            };
            backtrackingCurrentQ().examine(traverse);
            _flushAll();
            team.barrier(role);
        }
    }
        
    private def calDependency(w_mu: Long, w_delta: Double, w_sigma: Long, v: Vertex) {
        val locPred = OrgToLocSrc(v);
        val numUpdates = add_and_fetch[Int](numUpdates(), locPred, 1);
        val sigma = pathCount()(locPred) as Double;
        
        // lch()._dependenciesLock(locPred).lock();
        atomic {
            var dep: Double = 0;
            if (lch().linearScale) {
                dep = dependencies()(locPred) + (distance()(locPred) as Double / w_mu) * (sigma / w_sigma as Double) * (1 + w_delta);
            } else {
                dep = dependencies()(locPred) + ((sigma as Double)/ w_sigma ) * (1 + w_delta);
            }
            dependencies()(locPred) = dep;
        }
        // lch()._dependenciesLock(locPred).unlock();
        
        if(numUpdates == successorCount()(locPred)) {
            if (LocSrcToOrg(locPred) != lch().currentSource())
                score()(locPred) = score()(locPred) + dependencies()(locPred);
            backtrackingNextQ().set(locPred);
        }
        assert(successorCount()(locPred) > 0 
               && numUpdates()(locPred) <= successorCount()(locPred));
    }
    ///***************************** Debug ******************/
    private def print() {
        for (p in team.placeGroup()) {
            for (i in 0..(lch().numLocalVertices - 1)) {
                if (score()(i) > 0)
                    Console.OUT.println(LocSrcToOrg(i) + " " + score()(i));
            }
        }
    }
}