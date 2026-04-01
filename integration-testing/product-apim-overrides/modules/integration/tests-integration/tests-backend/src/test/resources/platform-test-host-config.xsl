<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:xs="automation_mapping.xsd">
    <xsl:output omit-xml-declaration="yes" indent="yes"/>

    <xsl:template match="node()|@*">
        <xsl:copy>
            <xsl:apply-templates select="node()|@*"/>
        </xsl:copy>
    </xsl:template>

    <!--setting execution environment to platform-->
    <xsl:template match="xs:executionEnvironment/text()">platform</xsl:template>

    <!--setting coverage false-->
    <xsl:template match="xs:coverage/text()">true</xsl:template>

    <!--setting host names — Azure AKS (DC1: eus2) -->
    <!--CP instances use localhost via kubectl port-forward (HTTP, no TLS) -->
    <xsl:template match="xs:instance[@name='store-old']/xs:hosts/xs:host/text()">localhost</xsl:template>
    <xsl:template match="xs:instance[@name='publisher-old']/xs:hosts/xs:host/text()">localhost</xsl:template>
    <xsl:template match="xs:instance[@name='keyManager']/xs:hosts/xs:host/text()">localhost</xsl:template>
    <xsl:template match="xs:instance[@name='gateway-mgt']/xs:hosts/xs:host/text()">localhost</xsl:template>
    <!--Gateway uses ingress hostname (REST API invocations, still HTTPS) -->
    <xsl:template match="xs:instance[@name='gateway-wrk']/xs:hosts/xs:host/text()">gw.eus2.apim.example.com</xsl:template>
    <xsl:template match="xs:instance[@name='backend-server']/xs:hosts/xs:host/text()">test-backends.apim.svc</xsl:template>

    <!--setting ports — CP: http=9763 (port-forward), https=19443 (port-forward); gateway on 443 (ingress); backend on 8080 -->
    <!--HTTP ports (used by our modified REST API clients via getWebAppURL) -->
    <xsl:template match="xs:instance[@name='store-old']/xs:ports/xs:port[@type='http']/text()">9763</xsl:template>
    <xsl:template match="xs:instance[@name='publisher-old']/xs:ports/xs:port[@type='http']/text()">9763</xsl:template>
    <xsl:template match="xs:instance[@name='keyManager']/xs:ports/xs:port[@type='http']/text()">9763</xsl:template>
    <xsl:template match="xs:instance[@name='gateway-mgt']/xs:ports/xs:port[@type='http']/text()">9763</xsl:template>
    <!--HTTPS ports (used by carbon-automation library's LoginLogoutClient, UserPopulator via getBackEndUrl) -->
    <xsl:template match="xs:instance[@name='store-old']/xs:ports/xs:port[@type='https']/text()">19443</xsl:template>
    <xsl:template match="xs:instance[@name='publisher-old']/xs:ports/xs:port[@type='https']/text()">19443</xsl:template>
    <xsl:template match="xs:instance[@name='keyManager']/xs:ports/xs:port[@type='https']/text()">19443</xsl:template>
    <xsl:template match="xs:instance[@name='gateway-mgt']/xs:ports/xs:port[@type='https']/text()">19443</xsl:template>
    <!--Gateway and backend ports -->
    <xsl:template match="xs:instance[@name='gateway-wrk']/xs:ports/xs:port/text()">443</xsl:template>
    <xsl:template match="xs:instance[@name='backend-server']/xs:ports/xs:port/text()">8080</xsl:template>

</xsl:stylesheet>
