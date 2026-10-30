using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public class RealtimeTests(ApiFixture fixture)
{
    [Fact]
    public async Task Persisted_message_is_delivered_to_authorized_hub_group_and_outsider_cannot_join()
    {
        using var c=fixture.CreateClient();
        var session=await (await c.PostAsJsonAsync("/api/v1/auth/login",new{email="producer@fruitvision.test",password=fixture.Password})).Content.ReadFromJsonAsync<JsonElement>();
        var access=session.GetProperty("accessToken").GetString()!;c.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",access);
        var conversations=await c.GetFromJsonAsync<JsonElement>("/api/v1/conversations");var id=conversations.GetProperty("items")[0].GetProperty("id").GetGuid();
        var wsClient=fixture.Server.CreateWebSocketClient();
        wsClient.ConfigureRequest=r=>r.Headers.Authorization="Bearer "+access;
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(12));
        using var ws=await wsClient.ConnectAsync(new Uri("ws://localhost/hubs/fruitvision"),timeout.Token);
        await Send(ws,new{protocol="json",version=1},timeout.Token);Assert.Equal("{}",await Read(ws,timeout.Token));
        await Send(ws,new{type=1,invocationId="forbidden",target="JoinConversation",arguments=new[]{Guid.NewGuid()}},timeout.Token);
        using(var denied=JsonDocument.Parse(await Read(ws,timeout.Token))){Assert.True(denied.RootElement.TryGetProperty("error",out _));}
        await Send(ws,new{type=1,invocationId="join",target="JoinConversation",arguments=new[]{id}},timeout.Token);
        using(var joined=JsonDocument.Parse(await Read(ws,timeout.Token))){Assert.False(joined.RootElement.TryGetProperty("error",out _));}
        var sent=await c.PostAsJsonAsync($"/api/v1/conversations/{id}/messages",new{clientMessageId=Guid.NewGuid().ToString("N"),text="Tin nhắn realtime kiểm thử"});sent.EnsureSuccessStatusCode();
        var message=await sent.Content.ReadFromJsonAsync<JsonElement>();
        JsonElement delivered=default;
        while(true){using var frame=JsonDocument.Parse(await Read(ws,timeout.Token));if(frame.RootElement.TryGetProperty("target",out var target)&&target.GetString()=="MessageCreated"){delivered=frame.RootElement.GetProperty("arguments")[0].Clone();break;}}
        Assert.Equal(message.GetProperty("id").GetGuid(),delivered.GetProperty("id").GetGuid());
        Assert.Equal("Tin nhắn realtime kiểm thử",delivered.GetProperty("text").GetString());
        (await c.PostAsync("/api/v1/auth/logout",null)).EnsureSuccessStatusCode();
        var disconnected=false;
        try{while(ws.State==WebSocketState.Open)await Read(ws,timeout.Token);disconnected=true;}
        catch(WebSocketException){disconnected=true;}
        Assert.True(disconnected,"Logout must close the authenticated realtime connection before the deadline.");
    }
    private static Task Send(WebSocket ws,object data,CancellationToken ct)=>ws.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(data)+"\u001e"),WebSocketMessageType.Text,true,ct);
    private static async Task<string> Read(WebSocket ws,CancellationToken ct)
    {
        using var buffer=new MemoryStream();var bytes=new byte[8192];
        while(true){var part=await ws.ReceiveAsync(bytes,ct);if(part.MessageType==WebSocketMessageType.Close)return "{}";buffer.Write(bytes,0,part.Count);if(part.EndOfMessage)break;}
        return Encoding.UTF8.GetString(buffer.ToArray()).TrimEnd('\u001e');
    }
}
