## Deploying Go applications to Windows Azure

Microsoft recently released [HttpPlatformHandler][hphAnn] for IIS. It can,
for instance, be used to host [Ruby on Rails applications on your IIS
host][hphRoR]. Azure Websites on the other hand has had this feature for
quite a while now, e.g. to host [customized JVM applications][hphJvm].
Through HttpPlatformHandler, Azure Websites can host any HTTP application,
including Go.

Hosting Go applications on Azure Websites has been [previously
documented][goAW]. However, as Go binaries are statically linked and
executed by the IIS through HttpPlatformHandler they are also locked for the
duration they are running.

Deploying newer versions of an application consequently involves first
shutting down the website. This issue is not isolated to Go as discussed in
issues [914][914] and [1122][1122] of the Kudu project. Although, as Go
binaries are statically linked it is to some extent easier to handle as we
will see below.

Let's see if we can automate deployment of Go applications to Azure
Websites.     

### In-place deployment of Go applications

Blog posts [here][jra] and [here][grisha], describe how to transparently
swap two binaries. Both rely on same approach, i.e.:

1. Spawning a child process and passing the file descriptor for the
HTTP-listening TCP socket from parent to child

2. Closing the listener on parent and let the child listen for traffic using
the passed file descriptor

3. Shutting down parent when its connections are closed

The latter portion of step 2 requires creating a `net.FileListener` which,
as of Go 1.4.1, is [unsupported on Windows][fileListener].

However, as Azure Websites will through HttpPlattformHandler automatically
invoke the application on incoming requests we only need to concern
ourselves with ensuring a graceful shutdown of the running application and
let HttpPlatformHandler invoke the latest application binary on incoming
requests. While this approach will cause new connections to be denied for a
short duration -- between closing of the socket and shutting down the
running process -- it is less obtrusive than having to manually shutting
down and restarting the website.

We can achieve an automated in-place deployment of Go applications by:

1. Closing the TCP socket on the running process

2. Shutdown the process once all its connections are closed

3. Configure HttpPlatformHandler to invoke and proxy new HTTP requests to
the new binary once shutdown is completed

### Closing TCP listener

In Go, `http.Serve` is used to serve HTTP over a `net.Listener`.
`http.Serve` will then block until the `Accept` method on the `net.Listener`
receiver returns an error, e.g. when the underlying file descriptor is
closed by calling `Close`. It follows that we can shutdown the HTTP server
and then the process if we first close the listener.

Through [embedding][embedStruct] we can by defining a new type
`stoppableListener` to extend the behavior of `net.Listener`.

	type stoppableListener struct {
		net.Listener
		initShutdown <-chan struct{}
	}

	func (l *stoppableListener) waitForClose() {
		go func() {
			<-l.initShutdown
			log.Println("Stopping listening for new connections")
			l.Listener.Close()
		}()
	}

Following this, we now have a method on a `stoppableListener` which will
close the underlying `net.Listener` once the receive operation on the
`initShutdown`-channel unblocks.

As `stoppableListener`, through embedding `net.Listener`, still fulfills the
`net.Listener` interface we can pass an instance of `stoppableListener` to
`http.Serve` and determine when to shutdown the HTTP server given send-access
on the `initShutdown`-channel.

### Shutting down the process

When control returns from `http.Serve`, following the closing of
`net.Listener`, we can shut down the process when remaining connections are
closed.

As the defined type `stoppableListener` embeds `net.Listener` we can also
modify the behavior of `Accept` to return another type that embeds
`net.Conn` and through it determine when all connections returned by
`Accept` have been closed. This detailed in the blogs posts referred to
[above](#in-place-deployment-of-go-applications).

### Triggering an in-placement deployment

[Kudu][kudu] is the deployment engine behind Azure Websites and supports
[custom deployment scripts][kuduScript]. As Kudu runs in a separate process
tree and Azure Websites will isolate processes from one another, Kudu
scripts are unable to directly initiate a shutdown of a running application,
e.g. by sending `SIGTERM` to the running process. However, we can use the
filesystem as a layer of indirection as it is shared by processes running on
the same site and account.

We create a file watcher which will close the `initShutdown`-channel when a
new file is found in the monitored directory referred to by the
`config.watchDir` variable below. Closing the channel will unblock the
receiver in the [listing above](#closing-tcp-listener) and initiate shutdown
by closing the TCP listener.

	func startWatcher(initShutdown chan<- struct{}, stopWatcher <-chan struct{}) {
		w, err := fsnotify.NewWatcher()
		if err != nil {
			log.Fatalf("Could not create watcher: %v", err)
		}

		go func() {
		Loop:
			for {
				select {
				case evt := <-w.Events:
					if evt.Op&fsnotify.Create == fsnotify.Create {
						log.Printf("New binary found. Preparing to shutdown.")
						close(initShutdown)
					}
				case err := <-w.Errors:
					log.Fatalf("File watcher error occurred: %v", err)
				case <-stopWatcher:
					w.Close()
					break Loop
				}
			}
		}()

		w.Add(config.watchDir)
	}

### Executing a new build

Any new requests to the site following shutdown completion will cause
HttpPlatformHandler to execute the binary or script file identified by the
value of the `processPath` attribute.

Provided it is possible to uniquely identify the latest build we can write a
batch script to have HttpPlatformHandler execute the latest build on each
invocation, e.g.

	SETLOCAL EnableDelayedExpansion
	SET /P ARTIFACT=<%HOME%\site\wwwroot\_artifact.txt
	!ARTIFACT! %*

if file `_artifact.txt` contains the path to the latest build.

(Unlike Kudu deployment scripts, bash scripts, unfortunately, does not seem
to be an option for HttpPlatformHandler.)

Given the name of the script above is `go-azure.bat`, HttpPlatformHandler
can be configured as follows, where the second argument is the directory
being monitored for new executables:

	<?xml version="1.0" encoding="UTF-8"?>
	<configuration>
	  <system.webServer>
	    <handlers>
	      <add name="httpPlatformHandler" path="*" verb="*" modules="httpPlatformHandler" resourceType="Unspecified" />
	    </handlers>
	    <httpPlatform processPath="%HOME%\site\wwwroot\go-azure.bat"
			  arguments="-port %HTTP_PLATFORM_PORT% %HOME%\site\wwwroot\_target"
			  startupRetryCount="3"
			  stdoutLogEnabled="true" />
	  </system.webServer>
	</configuration>

### Automating in-placement deployment with Kudu deploying script

As discussed above, we are able to trigger a shutdown of the application
given a new executable is put into the monitored directory. Given the path
to the new executable known, e.g. found in the contents of a file, we can
let HttpPlatformHandler invoke it through a script.

The remaining steps, then, are to ensure the newly compiled application is
given an unique name, stored within the monitored directory, and its path
stored in a file.

We can generated an unique name using variables from the [Azure
Website][azureEnv] and [Kudu deployment][kuduEnv] environments, more
specifically `WEBSITE_SITE_NAME` and `SCM_COMMIT_ID` from respective
environment.

	# Install go if needed
	export GOROOT=$HOME/go
	export PATH=$PATH:$GOROOT/bin
	export GOPATH=$DEPLOYMENT_SOURCE
	if [ ! -e "$GOROOT" ]; then
	  GO_ARCHIVE=$HOME/tmp/go.zip
	  mkdir -p ${GO_ARCHIVE%/*}
	  curl https://storage.googleapis.com/golang/go1.4.1.windows-amd64.zip -o $GO_ARCHIVE
	  # This will take a while ...
	  unzip $GO_ARCHIVE -d $HOME
	fi

	# Create and store unique artifact name
	DEPLOYMENT_ID=${SCM_COMMIT_ID:0:10}
	ARTIFACT_NAME=$WEBSITE_SITE_NAME-$DEPLOYMENT_ID.exe
	TARGET_ARTIFACT=$DEPLOYMENT_SOURCE/_target/$ARTIFACT_NAME
	echo $TARGET_ARTIFACT > _artifact.txt

	echo Building go artifact $TARGET_ARTIFACT from commit $DEPLOYMENT_ID
	go build -v -o $TARGET_ARTIFACT

Including the listing above in a (bash) [Kudu deployment script][kuduScript]
will install Go when necessary and build a statically linked binary named after
the website and the (short) commit hash from which the binary is built. For
instance, deploying from commit with hash
`6417057c21bf311adcb81fdb5ff78bf3b4908e71` to an Azure Website named `go-azure`
will create artifact `go-azure-6417057c21.exe`.

### Conclusion

In this post we show how to use HttpPlatformHandler to automate deployment
of Go applications to Azure Websites through Kudu deployment scripts. When
the site configured to deploy from a code repository, e.g. from GitHub, the
scripts will automatically initiate a build and deploy the resulting binary.

While it is difficult to achieve a (almost) seamless transition between two
Go binaries it is possible to minimize the window in which new requests are
denied by automatically triggering a shutdown when a new binary is found and
let HttpPlatformHandler invoke the new binary once shutdown is completed.

A sample project is [available on GitHub][repo].

[jra]: http://blog.nella.org/zero-downtime-upgrades-of-tcp-servers-in-go/
[grisha]: http://grisha.org/blog/2014/06/03/graceful-restart-in-golang/
[914]: https://github.com/projectkudu/kudu/issues/914
[1122]: https://github.com/projectkudu/kudu/issues/1122
[fileListener]: https://github.com/golang/go/blob/go1.4.1/src/net/file_windows.go#L25-28
[embedStruct]: https://golang.org/ref/spec#Struct_types
[hphAnn]: http://azure.microsoft.com/blog/2015/02/04/announcing-the-release-of-the-httpplatformhandler-module-for-iis-8/
[hphRoR]: http://www.hanselman.com/blog/AnnouncingRunningRubyOnRailsOnIIS8OrAnythingElseReallyWithTheNewHttpPlatformHandler.aspx
[hphRef]: http://www.iis.net/learn/extensions/httpplatformhandler/httpplatformhandler-configuration-reference
[azureEnv]: https://github.com/projectkudu/kudu/wiki/Azure-runtime-environment
[kuduEnv]: https://github.com/projectkudu/kudu/wiki/Deployment-Environment
[kuduScript]: https://github.com/projectkudu/kudu/wiki/Custom-Deployment-Script
[kudu]: https://github.com/projectkudu/kudu
[hphJvm]: http://azure.microsoft.com/en-us/documentation/articles/web-sites-java-custom-upload/
[goAW]: http://www.wadewegner.com/2014/12/4-simple-steps-to-run-go-language-in-azure-websites/
[repo]: https://github.com/hruan/go-azure
