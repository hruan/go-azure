package main

import (
	"flag"
	"fmt"
	"github.com/go-fsnotify/fsnotify"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

var config struct {
	port     int
	maxWait  int
	watchDir string
}

type semConn struct {
	net.Conn
}

var wg sync.WaitGroup

func (c semConn) Close() (err error) {
	err = c.Conn.Close()
	log.Printf("connection to %s closed", c.Conn.RemoteAddr())
	wg.Done()
	return
}

type stoppableListener struct {
	net.Listener
	initShutdown <-chan struct{}
}

func (l *stoppableListener) Accept() (c net.Conn, err error) {
	c, err = l.Listener.Accept()
	if err != nil {
		return
	}

	log.Printf("new connection from %s", c.RemoteAddr())
	c = semConn{Conn: c}
	wg.Add(1)

	return
}

func (l *stoppableListener) waitForClose() {
	go func() {
		<-l.initShutdown
		log.Println("Stopping listening for new connections")
		l.Listener.Close()
	}()
}

func init() {
	flag.IntVar(&config.port, "port", 8000, "HTTP port")
	flag.IntVar(&config.maxWait, "maxWait", 30, "Max seconds to wait clients before forcible termination")
}

func main() {
	flag.Parse()
	if flag.NArg() < 1 {
		printUsage()
	}
	config.watchDir = flag.Arg(0)

	flag.Visit(showFlags)

	l, err := net.Listen("tcp4", ":"+strconv.Itoa(config.port))
	if err != nil {
		log.Fatalf("Could not create listener: %v", err)
	}

	log.Println("Starting watcher")
	sync := startWatcher()

	sl := &stoppableListener{Listener: l, initShutdown: sync.newBinary}
	sl.waitForClose()

	defineHandlers()
	s := http.Server{
		ReadTimeout:    15 * time.Second,
		WriteTimeout:   15 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}

	log.Printf("Starting server: %+v", s)
	s.Serve(sl)

	log.Println("Stopping watching")
	close(sync.stopWatcher)

	log.Printf("Waiting for existing clients for upto %d seconds", config.maxWait)
	waitClients(time.Duration(config.maxWait) * time.Second)
}

func waitClients(maxWait time.Duration) {
	timeout := time.After(maxWait)
	allClosed := make(chan struct{})
	go func() {
		wg.Wait()
		close(allClosed)
	}()

	select {
	case <-timeout:
		log.Println("Maximum wait time exceeding. Terminating.")
		os.Exit(-1)
	case <-allClosed:
		log.Println("All connection closed. Shutting down.")
	}
}

func showFlags(f *flag.Flag) {
	log.Printf("Flag set: %s=%v", f.Name, f.Value)
}

func printUsage() {
	fmt.Println("Usage: go-azure-website <dir_to_watch>")
	os.Exit(0)
}

type synchronization struct {
	stopWatcher chan<- struct{}
	newBinary <-chan struct{}
}

func startWatcher() synchronization {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		log.Fatalf("Could not create watcher: %v", err)
	}

	stop := make(chan struct{})
	newBin := make(chan struct{})

	go func() {
	Loop:
		for {
			select {
			case evt := <-w.Events:
				if evt.Op&fsnotify.Create == fsnotify.Create {
					log.Printf("New binary found. Preparing to shutdown.")
					close(newBin)
				}
			case err := <-w.Errors:
				log.Fatalf("File watcher error occurred: %v", err)
			case <-stop:
				w.Close()
				break Loop
			}
		}
	}()

	w.Add(config.watchDir)
	return synchronization{newBinary: newBin, stopWatcher: stop}
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Add("Content-Type", "application/json")

	w.WriteHeader(http.StatusOK)

	fmt.Fprint(w, `{"message": "Hello from Azure Websites!"}`)
}

func defineHandlers() {
	http.HandleFunc("/", rootHandler)
}
