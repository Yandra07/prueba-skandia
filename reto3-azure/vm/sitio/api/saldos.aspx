<%@ Page Language="C#" %>
<script runat="server">
  void Page_Load() {
    System.Threading.Thread.Sleep(new System.Random().Next(30, 150));
    Response.ContentType = "application/json"; Response.Write("{\"saldo\":123456}");
  }
</script>
