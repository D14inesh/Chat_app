"""Self-signed TLS cert for LAN/HTTPS access. WebCrypto (the whole E2E flow)
only runs in a secure context — https:// or literal localhost — so a phone
on the same Wi-Fi needs HTTPS. Writes backend/certs/ and copies the same pair
to frontend/certs/. Re-run after the PC's LAN IP changes.

  python gen_cert.py
"""
import datetime
import ipaddress
import shutil
import socket

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from app.core.config import CERT_DIR, PROJECT_DIR


def lan_ips() -> list[str]:
    ips = set()
    for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
        ip = info[4][0]
        if not ip.startswith(("127.", "169.254.")):
            ips.add(ip)
    return sorted(ips)


def main():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Chat Application (local)")])
    ips = lan_ips()
    san = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
           x509.IPAddress(ipaddress.ip_address("::1"))]
    san += [x509.IPAddress(ipaddress.ip_address(ip)) for ip in ips]

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=825))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .sign(key, hashes.SHA256())
    )

    CERT_DIR.mkdir(parents=True, exist_ok=True)
    (CERT_DIR / "key.pem").write_bytes(key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
    (CERT_DIR / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))

    fe_certs = PROJECT_DIR / "frontend" / "certs"
    fe_certs.mkdir(parents=True, exist_ok=True)
    for f in ("key.pem", "cert.pem"):
        shutil.copy2(CERT_DIR / f, fe_certs / f)

    print(f"Certificate written to {CERT_DIR} and {fe_certs}")
    print("Covers: localhost, 127.0.0.1" + (", " + ", ".join(ips) if ips else ""))


if __name__ == "__main__":
    main()
