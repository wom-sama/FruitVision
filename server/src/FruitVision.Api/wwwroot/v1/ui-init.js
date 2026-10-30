"use strict";

(() => {
  const sameOriginRequest = (request) => {
    const target = new URL(request.url, window.location.href);
    if (target.origin !== window.location.origin ||
        !["http:", "https:"].includes(target.protocol) ||
        target.username || target.password) {
      throw new Error("Swagger chỉ gửi yêu cầu đến cùng máy chủ đang mở tài liệu.");
    }

    request.url = target.href;
    request.credentials = "same-origin";
    request.mode = "same-origin";
    request.redirect = "error";
    return request;
  };

  SwaggerUIBundle({
    url: "/openapi/v1.json",
    dom_id: "#swagger-ui",
    layout: "BaseLayout",
    presets: [SwaggerUIBundle.presets.apis],
    deepLinking: true,
    docExpansion: "list",
    defaultModelsExpandDepth: 1,
    displayRequestDuration: true,
    supportedSubmitMethods: ["get", "post", "put", "patch", "delete", "options", "head"],
    tryItOutEnabled: false,
    syntaxHighlight: false,
    validatorUrl: null,
    queryConfigEnabled: false,
    persistAuthorization: false,
    withCredentials: false,
    requestInterceptor: sameOriginRequest
  });
})();
