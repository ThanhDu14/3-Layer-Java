<%@ page language="java" contentType="text/html; charset=ISO-8859-1"
    pageEncoding="ISO-8859-1"%>
<%@ taglib prefix="c" uri="http://java.sun.com/jsp/jstl/core" %>
<!DOCTYPE html>
<html>
<head>
<meta charset="ISO-8859-1">
<title>Welcome to iwayQ Technology</title>
<link rel="stylesheet" href="/static/css/app.css">
</head>
<body>
Welcome <c:out value="${username}" />
<form method="post" action="logout">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}" />
    <input type="submit" value="Logout" />
</form>
  	  <h1 style="color:blue;" align="center"> iwayQ.com | Instant Information Site  </h1>
  	  <button onclick="window.location.href = 'http://www.iwayq.com';"> Home </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/gallery/gallery.html';"> Gallery </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Videos  </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Articles  </button>	  
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Tutorials  </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Assessment  </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Poll & Survey  </button>
	  <button onclick="window.location.href = 'http://www.iwayq.com/videos/videos.html';"> Chat  </button>

<%@ include file="_footer.jspf" %>
</body>
</html>