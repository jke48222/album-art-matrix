"""Normalize a user-entered reporter origin without accepting credentials or paths."""
import ipaddress
import re
from urllib.parse import urlsplit


def normalize_endpoint(value):
    if not isinstance(value, str):
        raise ValueError('Enter the Mac hostname and port.')
    value=value.strip()
    if not value:
        return ''
    if any(c.isspace() or ord(c)<32 for c in value) or len(value)>300:
        raise ValueError('Enter a hostname without spaces.')
    if '://' not in value:
        value='http://'+value
    try:
        parsed=urlsplit(value)
        host=parsed.hostname
        port=8787 if parsed.port is None else parsed.port
        if parsed.scheme not in ('http','https') or not host or parsed.username is not None or parsed.password is not None or parsed.path not in ('','/') or parsed.query or parsed.fragment or not 1<=port<=65535:
            raise ValueError()
        host=host.rstrip(".")
        if not host:
            raise ValueError()
        if ':' in host:
            ipaddress.IPv6Address(host)
            host='['+host.lower()+']'
        elif not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?',host):
            raise ValueError()
        return f'{parsed.scheme}://{host.lower()}:{port}'
    except (ValueError,TypeError):
        raise ValueError('Use a Mac hostname and port, such as studio-mac.local:8787.') from None
