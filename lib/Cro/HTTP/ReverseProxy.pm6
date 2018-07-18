use Cro;
use Cro::HTTP::Client;

class Cro::HTTP::ReverseProxy does Cro::Transform {
    has $.to;
    has $.to-absolute;
    has $!destination;
    has $!client = Cro::HTTP::Client.new;

    submethod TWEAK() {
        unless ($!to.defined ^^ $!to-absolute.defined) {
            die 'Either `to` or `to-absolute` must be specified for ReverseProxy';
        }
        $!to = self!trim-url($!to) if $!to ~~ Str;
        $!to-absolute = self!trim-url($!to-absolute) if $!to-absolute ~~ Str;
        with $!to {
            die '`to` of ReverseProxy must be a Str or code block' unless $!to ~~ Str|Callable;
            $!destination = $!to;
        }
        else {
            $!destination = $!to-absolute;
        }
    }

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method !trim-url($url) { $url.ends-with('/') ?? $url.substr(0, *-1) !! $url }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever $pipeline -> $request {
            unless $request ~~ Cro::HTTP::Request {
                die "Request middleware {self.^name} emitted a $request.^name(), " ~
                    "but a Cro::HTTP::Request was required";
            }
            my %options = headers => $request.headers;
            %options<body> = await $request.body if $request.has-body;

            whenever self!make-destination($request) {
                my $res = await $!client.request($request.method, $_, %options);
                emit $res;
            }
        }
    }

    method !make-destination(Cro::HTTP::Request $request) {
        my $target = $request.target;
        $target .= substr(1..*) if $target.starts-with('/');
        if $!destination ~~ Str {
            my $p = Promise.new;
            $p.keep($!to ?? "{$!destination}/$target" !! $!to-absolute);
            return $p;
        } else {
            my $dest-p = $!destination($request);
            if $dest-p ~~ Awaitable {
                return $dest-p.then({ .status ~~ Kept ?? do { my $url = self!trim-url(.result);
                                                              $!to ?? "$url/$target" !! "$url"
                                                            } !! die 'Failed to get URL' });
            } else {
                my $p = Promise.new;
                my $tmp = self!trim-url($dest-p);
                $p.keep($!to ?? "$tmp/$target" !! $tmp);
                return $p;
            }
        }
    }
}