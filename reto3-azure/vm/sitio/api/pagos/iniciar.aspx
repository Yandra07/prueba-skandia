<%@ Page Language="C#" %>
<script runat="server">
  void Page_Load() {
    System.Threading.Thread.Sleep(new System.Random().Next(40, 200));
    Response.ContentType = "application/json"; Response.Write("{\"sesion\":\"" + System.Guid.NewGuid() + "\"}");
  }
</script>
