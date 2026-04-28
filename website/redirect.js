// CloudFront Function (cloudfront-js-2.0) attached to viewer-request on
// the blackbird-terminal.com distribution.
//
// Two redirects:
//   1. www.blackbird-terminal.com -> blackbird-terminal.com (apex)
//   2. /index.html -> /                                     (canonicalize)
//
// Everything else passes through unchanged. Querystrings are preserved
// across both redirects. Cache-Control on the 301 lets browsers and
// CloudFront cache the redirect for a day so repeat visits skip the
// function entirely.

var CANONICAL_ORIGIN = 'https://blackbird-terminal.com';

function handler(event) {
    var request = event.request;
    var headers = request.headers;
    var host = (headers && headers.host && headers.host.value)
        ? headers.host.value.toLowerCase()
        : '';

    if (host.indexOf('www.') === 0) {
        return permanentRedirect(CANONICAL_ORIGIN + request.uri + querystring(request));
    }

    if (request.uri === '/index.html') {
        return permanentRedirect(CANONICAL_ORIGIN + '/' + querystring(request));
    }

    return request;
}

function permanentRedirect(location) {
    return {
        statusCode: 301,
        statusDescription: 'Moved Permanently',
        headers: {
            'location':       { value: location },
            'cache-control':  { value: 'public, max-age=86400' },
        },
    };
}

function querystring(request) {
    var qs = request.querystring;
    if (!qs) return '';
    var keys = Object.keys(qs);
    if (keys.length === 0) return '';
    var parts = [];
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var v = qs[k];
        // CloudFront supplies multi-valued keys via .multiValue.
        if (v.multiValue) {
            for (var j = 0; j < v.multiValue.length; j++) {
                parts.push(encodeKV(k, v.multiValue[j].value));
            }
        } else {
            parts.push(encodeKV(k, v.value));
        }
    }
    return '?' + parts.join('&');
}

function encodeKV(k, v) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(v);
}
