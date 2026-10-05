<%@ Page Language="C#" %>
<script runat="server">
  // /health "profundo": a diferencia del /health estático del caso, verifica lo que hizo fallar al portal.
  //  - memoria privada del proceso por encima del umbral  -> 503 (degradado)
  //  - dependencia simulada caída (C:\sitios\control\dependencia.caida) -> 503
  void Page_Load() {
    var p = System.Diagnostics.Process.GetCurrentProcess();
    long mb = p.PrivateMemorySize64 / (1024 * 1024);
    bool dep = !System.IO.File.Exists(@"C:\sitios\control\dependencia.caida");
    bool mem = mb < 1100;
    Response.ContentType = "application/json";
    Response.StatusCode = (dep && mem) ? 200 : 503;
    Response.Write(string.Format("{{\"estado\":\"{0}\",\"privadoMB\":{1},\"dependencia\":{2},\"pid\":{3}}}",
      (dep && mem) ? "ok" : "degradado", mb, dep ? "true" : "false", p.Id));
  }
</script>
