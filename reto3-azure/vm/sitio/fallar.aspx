<%@ Page Language="C#" %>
<script runat="server">
  // Inyección de fallas, SOLO desde la propia VM (Request.IsLocal). Nunca se expone a internet.
  //   ?modo=500    -> error 500
  //   ?modo=lento  -> 8 s de espera
  //   ?modo=crash  -> excepción no controlada en un hilo de fondo: termina w3wp.exe (igual que la OOM del 18-sep).
  //                   5 crashes en 5 min => Rapid-Fail Protection deshabilita el pool (WAS 5002).
  void Page_Load() {
    if (!Request.IsLocal) { Response.StatusCode = 403; Response.Write("solo local"); return; }
    string modo = (Request.QueryString["modo"] ?? "").ToLowerInvariant();
    switch (modo) {
      case "500": Response.StatusCode = 500; Response.Write("falla 500 provocada"); break;
      case "lento": System.Threading.Thread.Sleep(8000); Response.Write("lento"); break;
      case "crash":
        System.Threading.ThreadPool.QueueUserWorkItem(_ => { throw new System.OutOfMemoryException("Crash provocado (Reto 3)"); });
        System.Threading.Thread.Sleep(2000); Response.Write("crash enviado"); break;
      default: Response.StatusCode = 400; Response.Write("modo: 500 | lento | crash"); break;
    }
  }
</script>
