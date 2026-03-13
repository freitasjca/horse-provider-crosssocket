program server;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket Provider - Sample Server
  ============================================
  Demonstrates:
    * Basic routing
    * JSON response
    * Worker-pool offload for CPU-bound work
    * HTTPS (commented out)
    * Graceful shutdown
}

uses
  System.SysUtils,
  System.Classes,
  System.Threading,    // TTask
  Horse,
  Horse.Jhonson,       // JSON middleware (optional)
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool;

const
  SERVER_PORT = 9000;

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

procedure RegisterRoutes;
begin
  // Fast inline route - stays on IO thread
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType := 'text/plain';
      Res.Send('pong');
    end);

  // JSON echo
  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      Body: string;
    begin
      Body := Req.Body;
      Res.ContentType := 'application/json; charset=utf-8';
      Res.Send(Body);
    end);

  // CPU-bound work offloaded to the worker pool
  THorse.Get('/heavy',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      // Submit to worker pool; IO thread returns immediately.
      // NOTE: In a real async model the response would be sent from the
      // worker callback. Here we block the IO thread briefly for simplicity.
      // A production implementation would use CrossSocket's async reply API.
      THorseWorkerPool.Instance.Submit(
        procedure
        var
          I, Sum: Int64;
        begin
          Sum := 0;
          for I := 1 to 10_000_000 do Inc(Sum, I);
          // Signal back to the HTTP layer (simplified - see docs)
        end
      );
      Res.Send('{"status":"queued"}');
    end);

  // Pool diagnostics
  THorse.Get('/pool/stats',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType := 'application/json; charset=utf-8';
      Res.Send(
        Format('{"poolIdle":%d,"workerThreads":%d}',
          [THorseContextPool.IdleCount,
           THorseWorkerPool.Instance.ThreadCount])
      );
    end);
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

var
  StopEvent: TEvent;

begin
  try
    StopEvent := TEvent.Create(nil, True, False, '');
    try
      RegisterRoutes;

      // --- Plain HTTP ---
      THorseProviderCrossSocket.Listen(SERVER_PORT);
      Writeln(Format('[Horse/CrossSocket] Listening on http://0.0.0.0:%d', [SERVER_PORT]));

      // --- HTTPS example (uncomment + supply real cert/key) ---
      // var Cfg := THorseCrossSocketConfig.Default;
      // Cfg.SSLEnabled   := True;
      // Cfg.SSLCertFile  := 'cert.pem';
      // Cfg.SSLKeyFile   := 'key.pem';
      // THorseProviderCrossSocket.ListenWithConfig(9443, Cfg);
      // Writeln('[Horse/CrossSocket] TLS on https://0.0.0.0:9443');

      Writeln('Press ENTER to stop...');
      Readln;

    finally
      THorseProviderCrossSocket.Stop;
      StopEvent.Free;
      Writeln('Server stopped.');
    end;

  except
    on E: Exception do
    begin
      Writeln('Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
