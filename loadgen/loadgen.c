// loadgen.c — accept-bench connection storm + correctness-gate sampler (FIXED referee).
//
// Opens fresh TCP connections at a paced offered rate, each doing:
//   connect -> send fixed request -> recv exact REPLY_BYTES -> clean close.
// Measures offered/completed/failed conn/s and time-to-reply percentiles, and runs the
// correctness gate (exact reply bytes on a sample, completion audit, drop rate). Emits one JSON
// object on stdout. This is part of the referee; the optimizer never edits it.
//
// Design: N worker threads, each an epoll event loop driving non-blocking connections. Each
// thread paces new-connection starts to (rate/threads) per second and caps concurrent in-flight.
//
// Build: cc -O2 -o loadgen loadgen.c -lpthread
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/resource.h>

static const char REPLY[]   = "HTTP/1.1 200 OK\r\n\r\n";  // 19 bytes, byte-for-byte
static const int  REPLY_LEN = 19;
static const char REQUEST[] = "GET / HTTP/1.1\r\n\r\n";    // 18 bytes; arms read through \r\n\r\n
static const int  REQ_LEN   = 18;

// failure reasons
enum { F_CONNECT=0, F_RESET, F_TIMEOUT, F_TRUNC, F_WRONGBYTES, F_OTHER, F_NREASONS };
static const char *F_NAME[F_NREASONS] = {"connect","reset","timeout","truncated","wrongbytes","other"};

// latency histogram: 0..50ms in 50us buckets, plus overflow
#define HBUCKETS 1024
#define HUS_PER  50          // microseconds per bucket
#define MAX_INFLIGHT 60000

typedef struct {
    int    fd;
    int    state;            // 0=connecting,1=writing,2=reading
    int    got;              // reply bytes read so far
    int    sent;             // request bytes sent so far
    int    sampled;          // full-payload validation for this conn?
    char   rbuf[64];
    struct timespec t0;
} conn_t;

typedef struct {
    int      id, nthreads;
    char     host[64];
    int      port;
    double   rate;           // this thread's share, conn/s
    double   duration;       // seconds
    int      sample_pct;
    // results
    uint64_t offered, completed;
    uint64_t failed[F_NREASONS];
    uint64_t sampled_total, sampled_bad;
    uint64_t hist[HBUCKETS+1];
} worker_t;

static struct sockaddr_in g_addr;

static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }
static long us_since(struct timespec *a){ struct timespec b; clock_gettime(CLOCK_MONOTONIC,&b);
    return (b.tv_sec-a->tv_sec)*1000000L + (b.tv_nsec-a->tv_nsec)/1000; }

static int set_nonblock(int fd){ int f=fcntl(fd,F_GETFL,0); return fcntl(fd,F_SETFL,f|O_NONBLOCK); }

static void hist_add(worker_t *w, long us){ long b=us/HUS_PER; if(b<0)b=0; if(b>HBUCKETS)b=HBUCKETS; w->hist[b]++; }

static void conn_fail(worker_t *w, conn_t *c, int reason, int ep){
    if(c->fd>=0){ epoll_ctl(ep,EPOLL_CTL_DEL,c->fd,NULL); close(c->fd); c->fd=-1; }
    w->failed[reason]++;
}

static void conn_done(worker_t *w, conn_t *c, int ep){
    hist_add(w, us_since(&c->t0));
    w->completed++;
    epoll_ctl(ep,EPOLL_CTL_DEL,c->fd,NULL); close(c->fd); c->fd=-1;
}

// start one new connection (non-blocking connect). returns 0 ok, -1 fail (counted).
static int conn_start(worker_t *w, int ep, conn_t **slot){
    int fd = socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0);
    if(fd<0){ w->failed[F_OTHER]++; return -1; }
    int one=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof one);
    conn_t *c = calloc(1,sizeof *c);
    c->fd=fd; c->state=0; c->got=0; c->sent=0;
    c->sampled = (w->sample_pct>0) && ((w->offered % 100) < (uint64_t)w->sample_pct);
    clock_gettime(CLOCK_MONOTONIC,&c->t0);
    int r = connect(fd,(struct sockaddr*)&g_addr,sizeof g_addr);
    if(r<0 && errno!=EINPROGRESS){ close(fd); free(c); w->failed[F_CONNECT]++; return -1; }
    struct epoll_event ev; ev.events=EPOLLOUT; ev.data.ptr=c;
    epoll_ctl(ep,EPOLL_CTL_ADD,fd,&ev);
    *slot=c;
    w->offered++;
    return 0;
}

// returns 1 if the connection was resolved (completed or failed, and freed), 0 if still pending.
static int handle(worker_t *w, int ep, conn_t *c, uint32_t events){
    if(events & (EPOLLERR|EPOLLHUP)){
        int err=0; socklen_t l=sizeof err; getsockopt(c->fd,SOL_SOCKET,SO_ERROR,&err,&l);
        int reason = (c->state==0)?F_CONNECT : (err==ECONNRESET?F_RESET : (c->state==2?F_TRUNC:F_OTHER));
        conn_fail(w,c,reason,ep); free(c); return 1;
    }
    if(c->state==0){ // finishing connect
        int err=0; socklen_t l=sizeof err; getsockopt(c->fd,SOL_SOCKET,SO_ERROR,&err,&l);
        if(err){ conn_fail(w,c,F_CONNECT,ep); free(c); return 1; }
        c->state=1;
    }
    if(c->state==1){ // write request
        while(c->sent<REQ_LEN){
            ssize_t n=write(c->fd,REQUEST+c->sent,REQ_LEN-c->sent);
            if(n>0){ c->sent+=n; continue; }
            if(n<0 && (errno==EAGAIN||errno==EWOULDBLOCK)){
                struct epoll_event ev; ev.events=EPOLLOUT; ev.data.ptr=c; epoll_ctl(ep,EPOLL_CTL_MOD,c->fd,&ev); return 0; }
            conn_fail(w,c, errno==ECONNRESET?F_RESET:F_OTHER, ep); free(c); return 1;
        }
        c->state=2;
        struct epoll_event ev; ev.events=EPOLLIN; ev.data.ptr=c; epoll_ctl(ep,EPOLL_CTL_MOD,c->fd,&ev);
    }
    if(c->state==2){ // read reply
        while(c->got<REPLY_LEN){
            ssize_t n=read(c->fd, c->rbuf+c->got, REPLY_LEN-c->got);
            if(n>0){ c->got+=n; continue; }
            if(n==0){ conn_fail(w,c,F_TRUNC,ep); free(c); return 1; }           // closed early
            if(errno==EAGAIN||errno==EWOULDBLOCK) return 0;                      // wait for more
            conn_fail(w,c, errno==ECONNRESET?F_RESET:F_OTHER, ep); free(c); return 1;
        }
        // got REPLY_LEN bytes — validate
        int bad=0;
        if(c->sampled){ w->sampled_total++; if(memcmp(c->rbuf,REPLY,REPLY_LEN)!=0){ bad=1; w->sampled_bad++; } }
        else { if(c->rbuf[0]!='H' || c->rbuf[REPLY_LEN-1]!='\n') bad=1; }
        if(bad){ conn_fail(w,c,F_WRONGBYTES,ep); free(c); return 1; }
        conn_done(w,c,ep); free(c); return 1;
    }
    return 0;
}

static void *worker_main(void *arg){
    worker_t *w=arg;
    int ep=epoll_create1(0);
    struct epoll_event evs[1024];
    int inflight=0;
    double start=now_s(), tend=start+w->duration;
    double interval = w->rate>0 ? 1.0/w->rate : 1e9;   // seconds between starts
    double next_start = start;
    double drain_deadline = tend + 5.0;   // hard wall: never drain longer than 5s past tend
    while(1){
        double t=now_s();
        if(t>=tend && inflight==0) break;
        if(t>=drain_deadline){ w->failed[F_TIMEOUT]+=inflight; break; }  // stragglers => timeouts
        // launch due connections (paced), unless past duration or at inflight cap
        while(t<tend && t>=next_start && inflight<MAX_INFLIGHT){
            conn_t *c=NULL; if(conn_start(w,ep,&c)==0) inflight++;
            next_start += interval;
            if(next_start < t) next_start = t;  // don't build unbounded backlog
        }
        int n=epoll_wait(ep,evs,1024,1 /*ms*/);
        for(int i=0;i<n;i++){
            conn_t *c=evs[i].data.ptr;
            inflight -= handle(w,ep,c,evs[i].events);   // -1 only when the conn is resolved+freed
        }
    }
    close(ep);
    return NULL;
}

int main(int argc,char**argv){
    const char *host="127.0.0.1"; int port=31; double rate=1000, dur=5; int threads=4, sample=5;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--host")&&i+1<argc) host=argv[++i];
        else if(!strcmp(argv[i],"--port")&&i+1<argc) port=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--rate")&&i+1<argc) rate=atof(argv[++i]);
        else if(!strcmp(argv[i],"--duration")&&i+1<argc) dur=atof(argv[++i]);
        else if(!strcmp(argv[i],"--threads")&&i+1<argc) threads=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--sample-pct")&&i+1<argc) sample=atoi(argv[++i]);
    }
    if(threads<1)threads=1;
    // raise the open-fd limit: high-latency links need many concurrent connections in flight
    // (throughput = concurrency / latency); the default 1024 causes socket() EMFILE storms.
    { struct rlimit rl; rl.rlim_cur=rl.rlim_max=1048576;
      if(setrlimit(RLIMIT_NOFILE,&rl)!=0 && getrlimit(RLIMIT_NOFILE,&rl)==0){
        rl.rlim_cur=rl.rlim_max; setrlimit(RLIMIT_NOFILE,&rl); } }
    memset(&g_addr,0,sizeof g_addr);
    g_addr.sin_family=AF_INET; g_addr.sin_port=htons(port);
    if(inet_pton(AF_INET,host,&g_addr.sin_addr)!=1){ fprintf(stderr,"bad host %s\n",host); return 2; }

    worker_t *ws=calloc(threads,sizeof *ws);
    pthread_t *th=calloc(threads,sizeof *th);
    for(int i=0;i<threads;i++){
        ws[i].id=i; ws[i].nthreads=threads; ws[i].port=port; ws[i].rate=rate/threads;
        ws[i].duration=dur; ws[i].sample_pct=sample;
        pthread_create(&th[i],NULL,worker_main,&ws[i]);
    }
    for(int i=0;i<threads;i++) pthread_join(th[i],NULL);

    // aggregate
    uint64_t offered=0,completed=0,failed_total=0,failed[F_NREASONS]={0},stot=0,sbad=0;
    uint64_t hist[HBUCKETS+1]; memset(hist,0,sizeof hist);
    for(int i=0;i<threads;i++){
        offered+=ws[i].offered; completed+=ws[i].completed;
        stot+=ws[i].sampled_total; sbad+=ws[i].sampled_bad;
        for(int r=0;r<F_NREASONS;r++){ failed[r]+=ws[i].failed[r]; failed_total+=ws[i].failed[r]; }
        for(int b=0;b<=HBUCKETS;b++) hist[b]+=ws[i].hist[b];
    }
    // percentiles + tail (p99.9, max)
    uint64_t tot=completed; double p50us=0,p99us=0,p999us=0,maxus=0;
    if(tot>0){ uint64_t c=0; int p50set=0,p99set=0,p999set=0;
        for(int b=0;b<=HBUCKETS;b++) if(hist[b]>0) maxus=b*HUS_PER;   // highest non-empty bucket
        for(int b=0;b<=HBUCKETS;b++){ c+=hist[b];
            if(!p50set  && c>=tot*0.50 ){ p50us =b*HUS_PER; p50set=1;  }
            if(!p99set  && c>=tot*0.99 ){ p99us =b*HUS_PER; p99set=1;  }
            if(!p999set && c>=tot*0.999){ p999us=b*HUS_PER; p999set=1; break; } } }
    double drop = offered? (double)failed_total/offered : 0.0;
    double off_cps = dur>0? offered/dur:0, comp_cps = dur>0? completed/dur:0, fail_cps = dur>0? failed_total/dur:0;
    int reply_ok = (sbad==0);

    printf("{");
    printf("\"offered\":%lu,\"completed\":%lu,\"failed\":%lu,",offered,completed,failed_total);
    printf("\"offered_cps\":%.1f,\"completed_cps\":%.1f,\"failed_cps\":%.1f,",off_cps,comp_cps,fail_cps);
    printf("\"drop_rate\":%.6f,\"reply_ok\":%s,",drop,reply_ok?"true":"false");
    printf("\"sampled\":%lu,\"sampled_bad\":%lu,",stot,sbad);
    printf("\"p50_ms\":%.3f,\"p99_ms\":%.3f,\"p99_9_ms\":%.3f,\"max_ms\":%.3f,",p50us/1000.0,p99us/1000.0,p999us/1000.0,maxus/1000.0);
    printf("\"fail_reasons\":{");
    for(int r=0;r<F_NREASONS;r++) printf("%s\"%s\":%lu",r?",":"",F_NAME[r],failed[r]);
    printf("}}\n");
    return 0;
}
