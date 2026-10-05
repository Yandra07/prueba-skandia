<%@ Page Language="C#" %>
<script runat="server">
  // Portal de prueba (no es la app real de pagos): solo genera tráfico realista para IIS.
  void Page_Load() { System.Threading.Thread.Sleep(new System.Random().Next(10, 60)); }
</script>
<html><body><h1>PortalPagos (sitio de prueba · Reto 3)</h1></body></html>
