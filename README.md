### Varnish Docker Repository

[![Build Status](https://travis-ci.org/jonbaldie/varnish.svg?branch=master)](https://travis-ci.org/jonbaldie/varnish)

To use:

`docker pull jonbaldie/varnish`

Alternatively you can `git clone` the repo and run `make` from the project root.

### What is Varnish?

It's basically Redis for HTTP requests.

Instead of serving identical HTTP requests, eating up resources and bandwidth, Varnish caches requests for as long you like.

Just put it in front of your HTTP server, and it will intercept all HTTP requests.

It's one of the simplest ways to make your website faster.

### How does it work?

Expose Varnish on port 80, and point it to your web server using a `vcl` config file. See the Varnish docs (and Google) for details on how to do this.

For this Docker image, you can `ADD` your `default.vcl` file into `/etc/varnish/` inside the container. For my own setup I use Docker Compose with mounted volumes, which means any edits I make don't mean I have to rebuild the container.

### What about SSL?

Unfortunately Varnish doesn't understand HTTPS requests, so you have to do some creative rerouting of requests to make it work. This is how I do it in my setup:

HTTPS request ==> Nginx container port 443 ==> Varnish container port 80 ==> Nginx port 80 (internal) ==> Website.

HTTP request ==> Varnish container port 80 ==> Nginx port 80 (internal) ==> Website.

This may look ugly, but fortunately with Docker networking this is surprisingly easy to set up, and very performant.

(c) 2017 Jonathan Baldie
