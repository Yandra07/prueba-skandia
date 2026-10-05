"""Clientes del modelo de lenguaje.

ClienteAzureOpenAI: Azure OpenAI con Entra ID (sin API keys). El token sale de azure-identity si está instalado
(DefaultAzureCredential: identidad administrada, az login, etc.) o, si no, de `az account get-access-token`.
ClienteFalso: devuelve respuestas grabadas o fabricadas, para las pruebas.
"""
from __future__ import annotations
import json, os, subprocess, time
import urllib.error, urllib.parse, urllib.request

ALCANCE = "https://cognitiveservices.azure.com/.default"


class ErrorModelo(Exception):
    """Falla del proveedor (timeout, 429, 5xx, respuesta vacía, filtro de contenido)."""


def token_identidad_administrada(recurso: str) -> str | None:
    """Identidad administrada de Azure Automation / App Service (variables IDENTITY_ENDPOINT/IDENTITY_HEADER)."""
    ep, hdr = os.environ.get("IDENTITY_ENDPOINT"), os.environ.get("IDENTITY_HEADER")
    if not ep or not hdr:
        return None
    req = urllib.request.Request(f"{ep}?resource={urllib.parse.quote(recurso)}&api-version=2019-08-01",
                                 headers={"X-IDENTITY-HEADER": hdr, "Metadata": "true"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())["access_token"]


def _token() -> str:
    """Token de Entra ID. Cualquier falla de credencial se reporta como ErrorModelo, para que el motor use el respaldo."""
    try:
        return _token_sin_envolver()
    except ErrorModelo:
        raise
    except Exception as e:  # p. ej. ClientAuthenticationError de azure-identity o un IDENTITY_ENDPOINT caído
        raise ErrorModelo(f"Credencial de Entra ID no disponible ({type(e).__name__}): {e}") from e


def _token_sin_envolver() -> str:
    t = token_identidad_administrada("https://cognitiveservices.azure.com")
    if t:
        return t
    try:
        from azure.identity import DefaultAzureCredential  # type: ignore
        return DefaultAzureCredential(exclude_interactive_browser_credential=True).get_token(ALCANCE).token
    except ImportError:
        r = subprocess.run(["az", "account", "get-access-token", "--resource", "https://cognitiveservices.azure.com",
                            "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or not r.stdout.strip():
            raise ErrorModelo("No hay credencial de Entra ID: ejecute `az login` o use una identidad administrada")
        return r.stdout.strip()


class ClienteAzureOpenAI:
    def __init__(self, endpoint: str | None = None, despliegue: str | None = None, api_version: str = "2024-10-21",
                 timeout_s: float = 25, reintentos: int = 2):
        self.endpoint = (endpoint or os.environ.get("AZURE_OPENAI_ENDPOINT", "")).rstrip("/")
        self.despliegue = despliegue or os.environ.get("AZURE_OPENAI_DEPLOYMENT", "triage")
        if not self.endpoint:
            raise ErrorModelo("Defina AZURE_OPENAI_ENDPOINT")
        self.api_version, self.timeout_s, self.reintentos = api_version, timeout_s, reintentos
        self.nombre = f"azure-openai/{self.despliegue}"

    def completar(self, mensajes: list[dict], esquema: dict) -> tuple[str, dict]:
        url = f"{self.endpoint}/openai/deployments/{self.despliegue}/chat/completions?api-version={self.api_version}"
        cuerpo = json.dumps({
            "messages": mensajes, "temperature": 0, "max_tokens": 1800, "seed": 7,
            "response_format": {"type": "json_schema", "json_schema": {"name": "triage", "strict": True, "schema": esquema}},
        }).encode()
        ultimo = None
        for intento in range(self.reintentos + 1):
            t0 = time.monotonic()
            try:
                req = urllib.request.Request(url, data=cuerpo, method="POST", headers={
                    "Authorization": f"Bearer {_token()}", "Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=self.timeout_s) as r:
                    cuerpo_resp = r.read()
                try:
                    d = json.loads(cuerpo_resp)
                    ch = d["choices"][0]
                    contenido = ch["message"]["content"] or ""
                except (KeyError, IndexError, TypeError, ValueError) as e:
                    # HTTP 200 pero sin la forma esperada: no se reintenta, el motor usa el respaldo
                    raise ErrorModelo(f"Respuesta del modelo mal formada ({type(e).__name__}): {str(cuerpo_resp[:120])}") from e
                if ch.get("finish_reason") not in ("stop",):
                    raise ErrorModelo(f"finish_reason={ch.get('finish_reason')}")
                meta = {"modelo": d.get("model"), "tokens": d.get("usage"), "latencia_ms": int((time.monotonic() - t0) * 1000),
                        "intentos": intento + 1}
                return contenido, meta
            except urllib.error.HTTPError as e:
                ultimo = ErrorModelo(f"HTTP {e.code}: {e.read()[:200]!r}")
                if e.code not in (408, 429, 500, 502, 503, 504):
                    raise ultimo
            except (TimeoutError, urllib.error.URLError, OSError) as e:
                ultimo = ErrorModelo(f"Sin respuesta en {self.timeout_s}s: {e}")
            time.sleep(min(2 ** intento, 8))
        raise ultimo


class ClienteNoDisponible:
    """Se usa cuando el cliente real no se pudo crear (p. ej. falta AZURE_OPENAI_ENDPOINT): el motor recibe un
    ErrorModelo en la primera llamada y entrega el respaldo por reglas, en lugar de un traceback."""

    def __init__(self, motivo: str):
        self.motivo, self.nombre = motivo, "no-disponible"

    def completar(self, mensajes, esquema):
        raise ErrorModelo(self.motivo)


def crear_cliente(**kw):
    """ClienteAzureOpenAI, o ClienteNoDisponible con el motivo si no se puede crear."""
    try:
        return ClienteAzureOpenAI(**kw)
    except Exception as e:
        return ClienteNoDisponible(f"Cliente del modelo no disponible ({type(e).__name__}): {e}")


class ClienteFalso:
    """Para pruebas: una lista de respuestas (str) o excepciones, en orden."""

    def __init__(self, respuestas: list, nombre: str = "falso"):
        self.respuestas, self.nombre, self.llamadas = list(respuestas), nombre, []

    def completar(self, mensajes, esquema):
        self.llamadas.append(mensajes)
        r = self.respuestas.pop(0)
        if isinstance(r, Exception):
            raise r
        return r, {"modelo": self.nombre, "latencia_ms": 0, "intentos": 1}
