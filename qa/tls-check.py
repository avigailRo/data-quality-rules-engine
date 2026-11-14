"""TLS diagnostic for the LLM endpoint: which certificate-verification method works on this machine.
Prints only certificate issuers and OK/FAIL - no keys, no data. Usage: python tls-check.py <host> <ca-bundle.pem>"""
import socket
import ssl
import sys

host, bundle = sys.argv[1], sys.argv[2]


def try_ctx(name, ctx):
    try:
        with socket.create_connection((host, 443), timeout=15) as s, ctx.wrap_socket(s, server_hostname=host) as t:
            issuer = dict(x[0] for x in t.getpeercert()["issuer"])
            print(f"TLS {name}: OK (issuer: {issuer.get('organizationName', '')} / {issuer.get('commonName', '')})")
    except Exception as ex:  # diagnostic only
        print(f"TLS {name}: FAIL ({type(ex).__name__}: {ex})")


try_ctx("python-default", ssl.create_default_context())
c = ssl.create_default_context()
c.load_verify_locations(cafile=bundle)
try_ctx("windows-export-bundle", c)
try:
    import truststore
    try_ctx("truststore", truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
except ImportError:
    try:
        from pip._vendor import truststore
        try_ctx("truststore(pip-vendored)", truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
    except Exception as ex:
        print(f"truststore unavailable: {ex}")
