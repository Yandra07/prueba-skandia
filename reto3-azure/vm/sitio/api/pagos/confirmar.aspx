<%@ Page Language="C#" %>
<script runat="server">
  // Si existe C:\sitios\control\fuga.on, cada pago confirmado retiene ~0,5 MB en una lista estática:
  // reproduce el defecto de SesionPagoCache (Reto 1) para probar la alerta temprana de memoria y el reciclaje.
  static readonly System.Collections.Generic.List<byte[]> Cache = new System.Collections.Generic.List<byte[]>();
  void Page_Load() {
    System.Threading.Thread.Sleep(new System.Random().Next(60, 250));
    if (System.IO.File.Exists(@"C:\sitios\control\fuga.on")) { lock (Cache) { var b = new byte[512 * 1024]; b[0] = 1; b[b.Length - 1] = 1; Cache.Add(b); } }
    Response.ContentType = "application/json"; Response.Write("{\"confirmado\":true,\"retenidas\":" + Cache.Count + "}");
  }
</script>
